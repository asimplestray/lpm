-- lpm/pm/xbps.lua -- adaptador do gerenciador de pacotes do HOST (Void).
--
-- O lpm NÃO instala nada por conta própria: o download/conversão é com ele,
-- mas a instalação, o tracking de arquivos e a conferência de conflitos são
-- sempre decisão do xbps. Aqui ficam só as consultas locais que o preflight
-- e o CLI precisam.

local util = require("lpm.util")

local M = {}
M.id = "xbps"

local function q(args)
	-- saída de xbps-query quando não acha nada é vazia (código 1); é resposta
	-- válida, não erro.
	local out = util.capture("xbps-query " .. args .. " 2>/dev/null")
	return out or ""
end

-- v2.0: UMA passada textual no pkgdb alimenta as três consultas
-- (installed/shlib_provides/provides) — antes eram 3 varreduras completas do
-- mesmo arquivo (e um subprocesso). Memoizado por processo.

--- separa o virtual (provides) do xbps: 'cmd:sh-0_1' → 'sh';
-- o pkgver do xbps é nome-versão e a versão não contém '-', então o
-- '-<ver>' final some com dígitos de epoch na frente (mesma regra de split
-- do installed()).
function M.split_virtual(s)
	local rest = s:match("^cmd:(.+)$") or s
	-- pkgver do xbps = nome-versão: remove o '-<ver>' final
	local name = rest:match("^(.+)%-%d[%w._+:]*$") or rest
	return name
end

--- varredura textual da plist do xbps coletando pkgver, shlib-provides e
-- provides POR PACOTE. Serve aos DOIS formatos:
--   * single-file (pkgdb-0.38.plist e o index.plist do repodata): chave de
--     pacote a 1 tab + propriedades a partir de 2 tabs. CUIDADO: também há
--     array 'shlib-REQUIRES' — parser que não escopar o campo envenena o
--     mapa (experimento real em 20/10/2026); aqui cada propriedade só
--     alimenta o SEU campo (o resto zera o escopo ativo);
--   * legacy (db/<pkg>/plist): sem chave de pacote (cur = default_name o
--     arquivo todo) e propriedades a 1 tab.
-- returns inst {nome=ver}, shlibs {soname=pkg}, provides {virtual=pkg}
function M.scan_plist(data, default_name)
	local inst, shlibs, provides = {}, {}, {}
	local single = data:find("\n\t<dict>\n", 1, true) ~= nil
	local WANTED = { pkgver = true, ["shlib-provides"] = true, provides = true }
	local cur, pending, active = default_name, nil, nil
	for line in data:gmatch("[^\r\n]+") do
		local tabs, k2 = line:match("^(\t*)<key>([^<]+)</key>$")
		if tabs then
			-- formato single-file: 1 tab exato = chave de PACOTE (o dict vem
			-- logo a seguir); 2+ tabs = propriedade do pacote corrente
			if single and #tabs == 1 then
				pending = k2
				active = nil
			else
				active = WANTED[k2] and k2 or nil
			end
		elseif line == "\t<dict>" then
			if pending then cur = pending; pending = nil end
			active = nil
		elseif active then
			local v = line:match("<string>([^<]*)</string>")
			if v then
				if active == "pkgver" then
					-- pkgver de xbps: dígito (ou epoch) no começo da versão
					local n, ver = v:match("^(.+)%-(%d[%w._+:]*)$")
					if not n then n, ver = v:match("^(.+)%-(.+)$") end
					if n and ver then inst[n] = ver end
				elseif active == "shlib-provides" then
					if v:match("%.so") then shlibs[v] = cur end
				else -- provides
					local name = M.split_virtual(v)
					if name ~= "" then provides[name] = cur end
				end
			end
		end
	end
	return inst, shlibs, provides
end

local host_memo

--- estado do host em UMA passada: { inst={}, shlibs={}, provides={} }.
local function host_state()
	if host_memo then return host_memo end
	local st = { inst = {}, shlibs = {}, provides = {} }
	local data = util.read_file("/var/db/xbps/pkgdb-0.38.plist")
	if not data then
		data = util.read_file("/var/db/xbps/pkgdb.plist")
	end
	if data then
		local i, s, p = M.scan_plist(data, "(?)")
		st.inst, st.shlibs, st.provides = i, s, p
	else
		-- xbps antigo: um plist por pacote
		local out = util.capture("ls -1 /var/db/xbps/db 2>/dev/null")
		for pkg in (out or ""):gmatch("[^\r\n]+") do
			local pd = util.read_file("/var/db/xbps/db/" .. pkg .. "/plist")
			if pd then
				local i, s, p = M.scan_plist(pd, pkg)
				for n, v in pairs(i) do st.inst[n] = v end
				for n, v in pairs(s) do st.shlibs[n] = v end
				for n, v in pairs(p) do st.provides[n] = v end
			end
		end
	end
	host_memo = st
	return st
end

--- mapa { nome = versão } dos pacotes instalados.
function M.installed()
	return host_state().inst
end

-- shlib-provides do HOST ------------------------------------------------

--- mapa { soname = pkgname } do que os pacotes INSTALADOS providenciam.
function M.shlib_provides()
	return host_state().shlibs
end

-- provides do HOST ------------------------------------------------------

--- mapa { virtual = pkgname } do que os pacotes instalados PROVIDEm.
-- Os provê do xbps são do estilo 'cmd:sh-0_1' (virtual de COMANDO) ou de
-- nome cru ('awk'). v0.3: a cadeia de deps usa isto ANTES de recorrer ao
-- índice do doador (ex.: 'sh' que o xz pede é do bash do VOID, não do bash
-- do Arch).
function M.provides()
	return host_state().provides
end

-- quando o lpm for chamar o xbps pra instalar, é com estes comandos/flags
M.install_cmd = "xbps-install"
M.install_repo_flag = "-R"
M.remove_cmd = "xbps-remove"

return M
