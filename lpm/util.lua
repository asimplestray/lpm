-- lpm/util.lua -- utilidades comuns. Depende só da stdlib; chamadas externas
-- (tar, sha256sum, curl) são feitas via subprocessos porque toda distro alvo
-- tem esses binários, e assim o lpm não exige luarocks.

local M = {}

function M.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- filesystem -----------------------------------------------------------

local function file_exists(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	f:close()
	return true
end
M.file_exists = file_exists

function M.read_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local data = f:read("*a")
	f:close()
	return data
end

function M.write_file(path, data)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(data)
	f:close()
	return true
end

-- expansão de "~/" simples (Home)
function M.expand_path(p)
	if p:sub(1, 2) == "~/" then
		local home = os.getenv("HOME") or ""
		return home .. p:sub(2)
	end
	return p
end

-- shell ----------------------------------------------------------------

--- Executa cmd; retorna exitcode (e nil em falha local do próprio Lua).
function M.sh(cmd)
	local ok, kind, code = os.execute(cmd)
	if ok == nil then return nil end
	if type(ok) == "boolean" then
		return ok and 0 or 1
	end
	return ok
end

--- Captura stdout de cmd. Retorna out|nil, exitcode.
function M.capture(cmd)
	local f = io.popen(cmd, "r")
	if not f then return nil, -1 end
	local out = f:read("*a")
	local ok = f:close()
	return out, (ok and 0 or 1)
end

--- Primeiro binário existente no PATH entre os nomes dados.
function M.which(...)
	local names = { ... }
	for _, n in ipairs(names) do
		local out = M.capture("command -v -- " .. n .. " 2>/dev/null")
		local p = out and M.trim(out) or ""
		if p ~= "" then return p end
	end
	return nil
end

--- mkdir -p
function M.makedirs(path)
	return M.sh('mkdir -p -- ' .. "'" .. path:gsub("'", [['"'"']]) .. "'") == 0
end

--- junta componentes de caminho com '/'
function M.join(a, ...)
	local parts = { a, ... }
	for i = 1, #parts do
		parts[i] = (parts[i]:gsub("/+$", ""))
	end
	return table.concat(parts, "/")
end

--- verifica diretório existente (sem stat local, dá pra test via shell)
function M.dir_exists(path)
	-- puro Lua: abrir 'path/.' só funciona se path é diretório
	local fh = io.open(path .. "/.", "r")
	if fh then io.close(fh); return true end
	return false
end

--- assinatura de frescor de um arquivo: 'mtime:size' (v2.0).
-- Chave dos caches de índice: se o .db não mudou, o índice parseado do lpm
-- continua válido e o custo de extrair+parsear some do caminho quente.
function M.file_sig(path)
	if not path or path == "" then return nil end
	local esc_path = path:gsub("'", [['"'"']])
	local out = M.capture("stat -c '%Y:%s' -- '" .. esc_path .. "' 2>/dev/null")
	if not out then return nil end
	-- CUIDADO: 'and' em Lua produz EXATAMENTE 1 valor — atribuição multi
	-- capta SÓ o mtime. 'if/return' separado é obrigatório aqui.
	local t, s = M.trim(out):match("^(%d+):(%d+)$")
	if t and s then return t .. ":" .. s end
	return nil
end

--- estatística de diretório/arquivo (mtime para checagens de frescor)
function M.fmtime(path)
	local t = M.capture("stat -c '%Y' -- '" .. path:gsub("'", [['"'"']]) .. "' 2>/dev/null")
	return tonumber(t and M.trim(t) or "") or nil
end

-- serialização de tabelas (índice de repositório em cache) --------------

-- NOTA (v2.0): referências COMPARTILHADAS (mesma tabela em dois lugares —
-- o índice guarda cada entry em by_name E em list) NÃO são ciclo: serializam
-- como cópia. Ciclo de verdade é detectado pelo CAMINHO ATIVO da recursão
-- (ancestrais da chamada corrente), não por 'visited' global.

local function esc(s)
	return string.format("%q", s)
end

function M.dump(v, indent, parents)
	local parts = {}
	if type(v) ~= "table" then
		return { tostring(v) }  -- coerção para debug; índices são tabelas
	end
	parents = parents or {}
	if parents[v] then return { "<circular>" } end
	parents[v] = true
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, k in ipairs(keys) do
		local val = v[k]
		local kref
		if type(k) == "string" and k:match("^[%a_][%w_]*$") then
			kref = k .. " = "
		else
			kref = "[" .. (type(k) == "string" and esc(k) or tostring(k)) .. "] = "
		end
		local ref
		if type(val) == "table" then
			ref = "{\n" .. table.concat(M.dump(val, indent, parents), ",\n" .. string.rep("\t", indent)) .. "\n}"
		elseif type(val) == "string" then
			ref = esc(val)
		else
			ref = tostring(val)
		end
		parts[#parts + 1] = kref .. ref
	end
	parents[v] = nil -- sai do caminho ativo (o nó volta a ser serializável)
	return parts
end

function M.save(obj, path)
	local body = "return {\n" .. table.concat(M.dump(obj, 1), ",\n") .. "\n}\n"
	return M.write_file(path, body)
end

function M.load(path)
	local data = M.read_file(path)
	if not data then return nil end
	local chunk, err = load(data, "@" .. path, "t")
	if not chunk then return nil, err end
	return chunk()
end

return M
