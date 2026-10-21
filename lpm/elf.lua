-- lpm/elf.lua
--
-- Leitura de ELF puro Lua (stdlib 5.4: string.unpack), sem binutils.
-- Por quê: o preflight da 0.2 precisa saber DO PAYLOAD (não do índice do
-- doador) quais sonames os binários exigem (DT_NEEDED) e qual versão da
-- glibc eles exigem (vetores GLIBC_2.x de .gnu.version_r) — é aí que a
-- regra central "o doador nunca é mais novo que o host" vira fato
-- verificável por pacote, antes de qualquer .xbps existir.
--
-- Cobre: ELF64/ELF32 little-endian (x86_64 do Void; big-endian fica fora).
-- Não é um parser completo de ELF: só o suficiente para as seções dinâmicas
-- (PT_DYNAMIC + PT_LOAD) e para a .gnu.version_r caso haja DT_VERNEED.

local version = require("lpm.version")
local util = require("lpm.util")

local M = {}

local u32 = function(b, i) return ("<I4"):unpack(b, i) end
local u16 = function(b, i) return ("<I2"):unpack(b, i) end
-- tag/val dependem da classe: ELF64 8+8, ELF32 4+4
local dtval = 8

-- arquivo é ELF utilizável? retorna classe (64/32), msg|nil
local function open_elf(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local ident = f:read(16)
	if not ident or #ident < 6
		or ident:byte(1) ~= 0x7F or ident:sub(2, 4) ~= "ELF" then
		f:close()
		return nil, "não é ELF"
	end
	local cls, data = ident:byte(5), ident:byte(6)
	if data ~= 1 then f:close(); return nil, "não é little-endian" end
	if cls ~= 2 and cls ~= 1 then f:close(); return nil, "classe ELF desconhecida" end
	return f, cls -- f aberto; chamador fecha
end

-- ler campo do ehdr conforme a classe
local function ehdr_load(f, cls)
	f:seek("set")
	local hdr = f:read(cls == 2 and 64 or 52)
	local off, esz, num
	if cls == 2 then
		off = ("<I8"):unpack(hdr, 33)          -- e_phoff @32 (1-based 33)
		esz = u16(hdr, 55)                     -- e_phentsize @54
		num = u16(hdr, 57)                     -- e_phnum @56
	else
		off = u32(hdr, 29)                     -- @28
		esz = u16(hdr, 43)                     -- @42
		num = u16(hdr, 45)                     -- @44
	end
	return hdr, off, esz, num
end

--- análise de um ELF: { needed={sonames}, glibc_min="2.x"|nil } | nil, motivo
-- (motivo != nil também para estático/big-endian; o chamador da varredura
-- de payload trata "não parseável" como skipped, não como erro)
local function dyn_info(f, cls)
	local _, phoff, phentsize, phnum = ehdr_load(f, cls)
	if phnum == 0 or phoff == 0 then return nil, "sem program headers" end

	local ok64 = cls == 2
	local tagfmt = ok64 and "<I8" or "<I4"
	local vfmt = tagfmt
	local ent = ok64 and 16 or 8
	local valsz = ok64 and 8 or 4 -- d_tag é 8/4; d_val começa na MESMA largura

	f:seek("set", phoff)
	local phs = f:read(phnum * phentsize)

	local dyn_off, dyn_sz, loads = nil, nil, {}
	for i = 0, phnum - 1 do
		local base = 1 + i * phentsize -- base aponta para p_type (F=0)
		local ptype = u32(phs, base)
		-- Phdr ELF64: type@0 flags@4 offset@8 vaddr@16 filesz@32
		-- Phdr ELF32: type@0 offset@4 vaddr@8 filesz@16
		-- (string.unpack é 1-based sobre um bloco cujo início é base)
		if ptype == 2 then -- PT_DYNAMIC
			dyn_off = ok64 and ("<I8"):unpack(phs, base + 8) or u32(phs, base + 4)
			dyn_sz = ok64 and ("<I8"):unpack(phs, base + 32) or u32(phs, base + 16)
		elseif ptype == 1 then -- PT_LOAD
			loads[#loads + 1] = {
				off = ok64 and ("<I8"):unpack(phs, base + 8) or u32(phs, base + 4),
				vaddr = ok64 and ("<I8"):unpack(phs, base + 16) or u32(phs, base + 8),
				filesz = ok64 and ("<I8"):unpack(phs, base + 32) or u32(phs, base + 16),
			}
		end
	end
	if not dyn_off then return nil, "sem PT_DYNAMIC (estático?)" end

	-- tabela dinâmica: pares (tag,val)
	f:seek("set", dyn_off)
	local dyn = f:read(math.min(dyn_sz, 1 << 20))
	local needed_off, strtab_v, strsz_v, verneed_v = {}, nil, nil, nil
	local pos = 1
	local own = nil
	while pos + ent <= #dyn do
		local tag = (tagfmt):unpack(dyn, pos)
		local val = (vfmt):unpack(dyn, pos + valsz)
		pos = pos + ent
		if tag == 0 then break end -- DT_NULL
		if tag == 1 then needed_off[#needed_off + 1] = val end -- DT_NEEDED
		if tag == 5 then strtab_v = val end                   -- DT_STRTAB
		if tag == 10 then strsz_v = val end                   -- DT_STRSZ
		if tag == 14 then own = val end                       -- DT_SONAME
		if tag == 0x6ffffffe then verneed_v = val end         -- DT_VERNEED
	end
	if not strtab_v then return nil, "sem DT_STRTAB" end

	-- vaddr -> fileoff (dentro de um PT_LOAD: off = va - vaddr + off)
	local v2f = function(va)
		for _, l in ipairs(loads) do
			if va >= l.vaddr and va < l.vaddr + l.filesz then
				return l.off + (va - l.vaddr)
			end
		end
		return nil
	end

	local str_off = v2f(strtab_v)
	if not str_off then return nil, "DT_STRTAB fora dos PT_LOAD" end
	f:seek("set", str_off)
	-- bounded por DT_STRSZ; segundas marcas de fatias de 1 MB sem STRSZ
	local strs = f:read(math.min(strsz_v or (1 << 20), 1 << 26))
	local str_at = function(o)
		local e = strs and strs:find("\0", o + 1, true)
		return e and strs:sub(o + 1, e - 1) or nil
	end

	-- DT_VERNEED: requisito de versão de símbolos (GLIBC_2.x etc.)
	local glibs = {}
	if verneed_v then
		local v_off = v2f(verneed_v)
		if v_off then
			f:seek("set", v_off)
			local vs = f:read(1 << 16) -- Verneed é pequeno; teto de 64 KB
			-- Verneed: version u16@0, cnt u16@2, file u32@4, aux u32@8, next u32@12
			local b = 1
			while vs and b + 16 <= #vs do
				local aux = ("<I4"):unpack(vs, b + 8) -- vn_aux
				local nextvn = ("<I4"):unpack(vs, b + 12) -- vn_next
				-- Vernaux: hash u32@0, flags u16@4, other u16@6, name u32@8, next u32@12
				local ab = b + aux
				while vs and ab + 16 <= #vs do
					local name = ("<I4"):unpack(vs, ab + 8) -- vna_name
					local anext = ("<I4"):unpack(vs, ab + 12)
					local sym = str_at(name)
					if sym and sym:sub(1, 6) == "GLIBC_" then
						glibs[#glibs + 1] = sym:sub(7)
					end
					if anext == 0 then break end
					ab = ab + anext
				end
				if nextvn == 0 then break end
				b = b + nextvn
			end
		end
	end

	local glibc_min = nil
	for _, g in ipairs(glibs) do
		if not glibc_min or version.xbps_cmp(g, glibc_min) > 0 then glibc_min = g end
	end
	local needed = {}
	for _, o in ipairs(needed_off) do
		local s = str_at(o)
		if s then needed[#needed + 1] = s end
	end
	return {
		needed = needed,
		me = own and (str_at(own)) or nil, -- DT_SONAME próprio, para libs do payload
		glibc_min = glibc_min,
	}
end

--- varre um diretório de payload (staging) e devolve dados agregados:
-- {
--   elf = n (quantos ELF parseados),
--   skipped = n (arquivos que não são ELF ou fora de alcance),
--   needed = { soname = contagem }, needed_names = { ordenado },
--   self = { soname = true } que o próprio payload provê (DT_SONAME),
--   glibc_min = "2.x" | nil,
-- }
-- Só ELF little-endian; arquivos ilegíveis contam como skipped.
function M.scan(dir)
	local out, code = util.capture("find " .. dir .. " -type f -print 2>/dev/null")
	local res = { elf = 0, skipped = 0, needed = {}, file_needed = {}, self = {}, glibc_min = nil }
	if not out then return res end

	-- Gêmeos de plataforma (v2.0.2): o ecossistema npm/prebuilds embarca o
	-- mesmo addon duas vezes — `...-linux-x64-glibc/` e `...-linux-x64-musl/`
	-- (@parcel/watcher, por exemplo). No host glibc o twin musl NUNCA é
	-- carregado (o JS resolve por require-optional e cai no glibc), mas o
	-- scan agrega os DT_NEEDED dele e inventa uma exigência de
	-- libc.musl-x86_64.so.1 que paralisa a transação. Prúna: só quando o
	-- twin glibc REALMENTE existe na mesma árvore (se não existir, o binário
	-- seria o único e a incompatibilidade deve continuar falando).
	local paths, dirSet = {}, {}
	for p in out:gmatch("[^\r\n]+") do
		paths[#paths + 1] = p
		local parent = p:match("^(.*)/[^/]+$")
		if parent then dirSet[parent] = true end
	end
	local function twin_glibc(p)
		local dir, tail = p:match("^(.*/[^/]*linux%-x64%-musl)(/.*)$")
		if dir then
			local twin = dir:gsub("linux%-x64%-musl$", "linux-x64-glibc") .. tail
			local parent = twin:match("^(.*)/[^/]+$")
			if dirSet[parent] then return twin end
		end
		return nil
	end
	res.excluded_twins, res.skipped_twins = {}, 0

	for _, p in ipairs(paths) do
		local twin = twin_glibc(p)
		if twin then
			-- conta como incluída para o skipped não mascarar
			res.skipped_twins = res.skipped_twins + 1
			if #res.excluded_twins < 8 then
				res.excluded_twins[#res.excluded_twins + 1] = p
			end
		else
			local f, cls = open_elf(p)
			if not f then
				res.skipped = res.skipped + 1
			else
				local info = dyn_info(f, cls)
				f:close()
				if info then
					res.elf = res.elf + 1
					for _, s in ipairs(info.needed) do
						res.needed[s] = (res.needed[s] or 0) + 1
					end
					-- v2.0.4: atribuição por ARQUIVO — o prompt S/N mostra
					-- exatamente quem precisa do soname órfão
					if #info.needed > 0 then
						res.file_needed[p] = info.needed
					end
					if info.me then res.self[info.me] = true end
					if info.glibc_min then
						if not res.glibc_min or version.xbps_cmp(info.glibc_min, res.glibc_min) > 0 then
							res.glibc_min = info.glibc_min
						end
					end
				else
					res.skipped = res.skipped + 1
				end
			end
		end
	end
	-- lista ordenada, determinística, para saída de CLI/testes
	local lst = {}
	for s in pairs(res.needed) do lst[#lst + 1] = s end
	table.sort(lst)
	res.needed_names = lst
	return res
end

--- v2.0.4: quais arquivos do payload exigem `soname` (diagnóstico do S/N).
-- Ordenado para saída determinística.
function M.files_needing(scan, soname)
	local out = {}
	for p, needs in pairs((scan and scan.file_needed) or {}) do
		for _, s in ipairs(needs) do
			if s == soname then
				out[#out + 1] = p
				break
			end
		end
	end
	table.sort(out)
	return out
end

return M
