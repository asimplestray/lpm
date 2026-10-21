-- lpm/repos/arch.lua
--
-- Índice de repositório do pacman (o doador da primeira build).
--
-- Formato de core.db / extra.db: tarball (xz ou zstd) com um diretório por
-- pacote; dentro, arquivos de texto de chaves %CHAVE%:
--
--   %FILENAME%
--   linux-6.1.12-1-x86_64.pkg.tar.zst
--
--   %NAME%
--   linux
--
-- `desc` carrega metadados (nome, versão, provides, conflicts...);
-- `depends` carrega %DEPENDS% / %OPTDEPENDS%. Um parser genérico lê os dois.

local util = require("lpm.util")
local version = require("lpm.version")

local M = {}
M.id = "arch"

if not util.which("tar") then
	error("lpm/repos/arch: preciso de 'tar' no PATH")
end

-- extração do banco ----------------------------------------------------

--- desempacota um .db (tar.xz/zstd/tar cru) para o diretório out.
-- GNU tar 1.31+ detecta xz/zstd automaticamente se os binários existirem
-- (existem em todo host alvo; nessa máquina de dev, tar cru para testes).
-- Extração em `out.tmp.pid` + troca: sobra de extração anterior (pacote que
-- saiu do repo) não pode vazar no search.
function M.extract_db(db_path, out)
	local tmp = out .. ".tmp." .. os.time()
	if not util.makedirs(tmp) then
		return nil, "could not create " .. tmp
	end
	local cmd = string.format("tar -xf '%s' -C '%s'", db_path, tmp)
	if util.sh(cmd) ~= 0 then
		util.sh("rm -rf -- '" .. tmp .. "'")
		return nil, "failed to unpack " .. db_path .. " (are xz/zstd installed?)"
	end
	util.sh("rm -rf -- '" .. out .. "'")
	if os.rename(tmp, out) == nil then
		return nil, "could not rename " .. tmp .. " → " .. out
	end
	return true
end

-- parsing --------------------------------------------------------------

--- parser genérico dos arquivos %CHAVE% do .db.
-- retorna { CHAVE = { val1, val2, ... } }
function M.parse_db_file(text)
	local fields = {}
	local key = nil
	for line in text:gmatch("[^\n]+") do
		if line:byte(1) == 37 and line:byte(#line) == 37 then -- %CHAVE%
			local k = line:sub(2, #line - 1)
			if k ~= "" then
				key = k
				fields[key] = fields[key] or {}
			end
		else
			local v = util.trim(line)
			if v ~= "" and key then
				table.insert(fields[key], v)
			end
		end
	end
	return fields
end

--- monta uma entrada a partir das tabelas de campos %CHAVE% (desc e depends)
function M.build_entry(descf, depf)
	if not descf or not descf.NAME or not descf.NAME[1] then return nil end
	local entry = {
		donor = M.id,
		name = descf.NAME[1],
		base = descf.BASE and descf.BASE[1] or nil,
		version = descf.VERSION and descf.VERSION[1] or nil,
		filename = descf.FILENAME and descf.FILENAME[1] or nil,
		desc = descf.DESC and descf.DESC[1] or "",
		sha256 = descf.SHA256SUM and descf.SHA256SUM[1] or nil,
		csize = descf.CSIZE and tonumber(descf.CSIZE[1]) or nil,
		isize = descf.ISIZE and tonumber(descf.ISIZE[1]) or nil,
		arch = descf.ARCH and descf.ARCH[1] or nil,
		url = descf.URL and descf.URL[1] or nil,
		license = descf.LICENSE or {},
		provides = descf.PROVIDES or {},
		conflicts = descf.CONFLICTS or {},
		replaces = descf.REPLACES or {},
		groups = descf.GROUPS or {},
		depends = {},
	}
	-- os .db atuais do Arch embutem %DEPENDS%/%OPTDEPENDS% no próprio `desc`;
	-- formato antigo tinha arquivo `depends` separado. Aceitar os dois.
	local dsrc = (depf and depf.DEPENDS) or descf.DEPENDS or {}
	for _, raw in ipairs(dsrc) do
		local pd = version.parse_dep(raw)
		if pd then table.insert(entry.depends, pd) end
	end
	return entry
end

--- constrói o índice a partir do diretório JÁ extraído do .db.
-- retorna { by_name = {nome=entry}, by_provides = {nome=entry}, list = {...} }
function M.build_index(dir)
	local names = util.capture("ls -1 '" .. dir .. "' 2>/dev/null")
	if not names then
		return nil, "could not list " .. dir
	end
	local by_name, by_provides, list = {}, {}, {}
	for pkgdir in names:gmatch("[^\r\n]+") do
		local pdir = dir .. "/" .. pkgdir
		local descf = M.parse_db_file(util.read_file(pdir .. "/desc") or "")
		local depf_text = util.read_file(pdir .. "/depends")
		local depf = depf_text and M.parse_db_file(depf_text) or nil
		local entry = M.build_entry(descf, depf)
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
	return { by_name = by_name, by_provides = by_provides, list = list }
end

return M
