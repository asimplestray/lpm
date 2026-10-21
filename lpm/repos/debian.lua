-- lpm/repos/debian.lua
--
-- Índice de repositório Debian/Ubuntu (doador futuro, pós-Void).
--
-- Formato: dists/<suite>/main/binary-amd64/Packages.gz (.xz) — texto plano,
-- estrofes de "Campo: valor" separadas por linha em branco, valores
-- multi-linha com indentação.
--
-- Versões são da língua dpkg (ver lpm/version.lua).

local util = require("lpm.util")
local version = require("lpm.version")

local M = {}
M.id = "deb"

local function split_commas(s)
	local out = {}
	s = s:gsub(",%s*", ",") -- '< >' não aparece dentro de "(>= 1.2)"
	for item in s:gmatch("[^,\n]+") do
		item = util.trim(item)
		if item ~= "" then table.insert(out, item) end
	end
	return out, #out
end

local function parse_stanza(stanza)
	local rec = {}
	local lastkey
	for line in stanza:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w%-]+): ?(.*)$")
		if k then
			rec[k] = v
			lastkey = k
		elseif line:byte(1) == 32 and lastkey then
			rec[lastkey] = (rec[lastkey] or "") .. "\n" .. util.trim(line)
		end
	end
	return rec
end

local function parse_dep_item(part)
	-- "libc6 (>= 2.34)"  /  "libc6"  /  "libc6:t64 (>= 2.34)"
	local name = part:match("^(%S+)")
	if not name then return nil end
	local op, ver = part:match("%(%s*([<>]?=?=?)%s*([^%)]+)%)")
	return { name = name, op = op, ver = ver and util.trim(ver) or nil }
end

function M.build_entry(rec)
	if not rec or not rec.Package or not rec.Version then return nil end
	local entry = {
		donor = M.id,
		name = rec.Package,
		version = rec.Version,
		filename = rec.Filename,
		desc = (rec.Description or ""):match("^([^\n]+)") or "",
		arch = rec.Architecture or nil,
		url = rec.Homepage or nil,
		size = tonumber(rec["Installed-Size"] or "") or nil,
		sha256 = (rec.SHA256 or "") ~= "" and rec.SHA256 or nil,
		license = {},
		provides = rec.Provides and (function()
			-- provides Debian pode vir com constraint ' (= 2.18)': o lpm
			-- guarda só o NOME (a versão do provide é a do próprio pacote)
			local ys = {}
			for item in rec.Provides:gmatch("[^,]+") do
				local n = item:gsub("^%s+", ""):match("^([^%( ]+)")
				if n and n ~= "" then ys[#ys + 1] = n end
			end
			return ys
		end)() or {},
		conflicts = rec.Breaks and split_commas(rec.Breaks) or {},
		replaces = rec.Replaces and split_commas(rec.Replaces) or {},
		depends = {},
		optdepends = rec.Recommends and split_commas(rec.Recommends) or {},
	}
	if rec.Depends then
		for _, grp in ipairs(split_commas(rec.Depends)) do
			-- "liba (>= 1) | libb" -> primeira alternativa por enquanto (TODO: união)
			local alt = util.trim(grp:match("^(.-)|") or grp)
			local pd = parse_dep_item(alt)
			if pd then table.insert(entry.depends, pd) end
		end
	end
	-- mapeamento de arquitetura Debian → xbps (a cadeia instala no host
	-- x86_64; Debian chama amd64 — xbps-create -A exige o nome do xbps)
	if entry.arch == "amd64" then entry.arch = "x86_64"
	elseif entry.arch == "arm64" then entry.arch = "aarch64"
	elseif entry.arch == "i386" then entry.arch = "i686"
	elseif entry.arch == "all" then entry.arch = "noarch"
	else entry.arch = nil end
	return entry
end

function M.build_index(text_or_dir)
	-- API comum ao load_indices do CLI: recebe TEXTO (estância stanzas) ou
	-- um DIRETÓRIO com o arquivo 'Packages' (contrato igual ao repos.arch).
	if util.dir_exists(text_or_dir) then
		text_or_dir = util.read_file(text_or_dir .. "/Packages") or ""
	end
	local by_name, by_provides, list = {}, {}, {}
	for stanza in (text_or_dir .. "\n\n"):gmatch("(.-)\n\n") do
		if util.trim(stanza) ~= "" then
			local entry = M.build_entry(parse_stanza(stanza))
			if entry then
				list[#list + 1] = entry
				by_name[entry.name] = entry
				for _, raw in ipairs(entry.provides) do
					local pn = version.parse_dep(raw)
					if pn and pn.name and pn.name ~= entry.name and not by_provides[pn.name] then
						by_provides[pn.name] = entry
					end
				end
			end
		end
	end
	return { by_name = by_name, by_provides = by_provides, list = list }
end

-- conversão de índice/comando do CLI --------------------------------------

--- extrai o índice GZ do doador para o CONTEXTO do CLI (contrato arch):
-- <repo>.db baixado é Packages.gz → descomprime para <exdir>/Packages.
function M.extract_db(dbpath, exdir)
	util.makedirs(exdir)
	local out, code = util.capture("gzip -dc " .. "'" .. dbpath .. "'")
	if code ~= 0 or not out or out == "" then
		return nil, "gzip -dc failed on " .. dbpath
	end
	local fh = io.open(exdir .. "/Packages", "w")
	if not fh then return nil, "could not write " .. exdir .. "/Packages" end
	fh:write(out)
	fh:close()
	return exdir
end

-- payload .deb ------------------------------------------------------------

--- extrai o membro data.tar.* de um .deb (formato 'ar') direto no staging.
-- `ar` NÃO existe na máquina do projeto (binutils ausente) e o lpm é 100%
-- Lua: o header 'ar' é simples e parseado a dedo:
--   magic "!<arch>\n" (8) + por membro: name(16) mtime(12) uid(6) gid(6)
--   mode(8) size(10) `\`\n`(2) — conteúdo segue, com pad de 1 byte se ímpar.
-- O control.tar.* (scripts do doador) é IGNORADO — regra central: nada do
-- doador roda no host; só de payload (tar auto-detecta zst/gz/xz por magic).
function M.stage(deb_path, staging_dir)
	local fh = io.open(deb_path, "rb")
	if not fh then return nil, "could not open " .. deb_path end
	local magic = fh:read(8)
	if magic ~= "!<arch>\n" then
		fh:close()
		return nil, "not an ar archive (.deb): " .. deb_path
	end
	while true do
		local hdr = fh:read(60)
		if not hdr then break end
		if #hdr < 60 then fh:close(); return nil, "truncated ar: " .. deb_path end
		local name = util.trim(hdr:sub(1, 16):gsub("/", ""))
		local size = tonumber(hdr:sub(49, 58)) or 0
		local clean_name = name:match("^(data%.tar)")
		if clean_name then
			-- é o payload: copia o membro inteiro
			local tmp = staging_dir .. "/payload_" .. (name:match("%.([a-z0-9]+)$") or "tar")
			local body = fh:read(size)
			fh:close() -- o resto do arquivo não interessa (control.*, etc.)
			if not body or #body ~= size then
				return nil, "member " .. name .. " incomplete in " .. deb_path
			end
			local ok, err = pcall(function()
				local tf = assert(io.open(tmp, "w+b"))
				assert(tf:write(body))
				tf:close()
			end)
			if not ok then return nil, err end
			-- decompressão conforme magic: zstd/gzip nativos; xz NÃO existe
			-- no host → python3 (stdlib lzma do mesmo binário do sistema)
			local fds = io.open(tmp, "rb")
			local head = fds and fds:read(6) or ""
			if fds then fds:close() end
			local plain = tmp .. ".tar"
			if head:sub(1, 4) == "\40\181\47\253" then -- zstd
				if util.sh("zstd -d -f '" .. tmp .. "' -o '" .. plain .. "' 2>&1") ~= 0 then
					return nil, "zstd -d failed: " .. tmp
				end
			elseif head:sub(1, 2) == "\31\139" then -- gzip
				local txt, code = util.capture("gzip -dc '" .. tmp .. "' > '" .. plain .. "' 2>&1")
				if code ~= 0 then return nil, "gzip -d failed: " .. (txt or "") end
			elseif head:sub(2, 5) == "7zXZ" then -- xz (FD 37 7A 58 5A)
				local txt, code = util.capture(
					"python3 -c 'import sys,lzma; sys.stdout.buffer.write("
					.. "lzma.decompress(sys.stdin.buffer.read()))' "
					.. "< '" .. tmp .. "' > '" .. plain .. "' 2>&1")
				if code ~= 0 then return nil, "lzma (python3) failed: " .. (txt or "") end
			else
				return nil, "payload " .. name .. " has unknown compression: " .. deb_path
			end
			os.remove(tmp)
			if util.sh("tar -xf '" .. plain .. "' -C '" .. staging_dir .. "' 2>&1") ~= 0 then
				return nil, "tar -xf of the payload failed: " .. plain
			end
			os.remove(plain)
			return staging_dir
		end
		-- membro ignorado (control.tar.*, debian-binary, etc.): pula
		fh:seek("cur", size + (size % 2 == 1 and 1 or 0))
	end
	fh:close()
	return nil, "cannot find data.tar.* member in " .. deb_path
end

return M
