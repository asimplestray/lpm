-- lpm/repos/xbpsrepo.lua
--
-- O repodata dos repositórios do PRÓPRIO xbps (o host), que aqui vira a
-- PONTE AUTOMÁTICA de nomes da v2.0. O repodata oficial declara, por
-- pacote, `shlib-provides` e `provides`; com isso o lpm resolve nomes em
-- mundos "incompatíveis" SEM tabela nenhuma: o do doador se chama 'gtk3',
-- o do Void 'gtk+3' — os sonames declarados pelos dois são os mesmos
-- (libgtk-3.so.0 …), e essa é a prova de que são o MESMO componente.
--
-- Fonte: o cache do próprio xbps em /var/db/xbps/<repo-url>/<arch>-repodata.
-- É o MESMO índice que o solver nativo consulta no momento da instalação —
-- a ponte nunca diverge daquilo que `sudo xbps-install -R` vai resolver.
-- Sem rede aqui: se o xbps nunca sincronizou, cai para o downloader do
-- lpm uma única vez e guarda em cache próprio.
--
-- Mapa parseado vai para ~/.cache/lpm/void/<repo>.lua, chaveado pela
-- assinatura (mtime:size) do repodata — novo sync do xbps muda a
-- assinatura e o cache se refaz sozinho. Zera o custo por comando.

local util = require("lpm.util")
local prereq = require("lpm.pm.xbps")

local M = {}
M.id = "xbpsrepo"

local function esc(s)
	return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

--- URL → nome de diretório do cache do xbps:
-- https://repo-default.voidlinux.org/current → https___repo-default_voidlinux_org_current
local function safe(url) return (url:gsub("[^%w%-]", "_")) end

local arch_memo

--- arch do host (uname), no idioma dos nomes de repodata do xbps
function M.host_arch()
	if not arch_memo then
		arch_memo = util.trim(util.capture("uname -m 2>/dev/null") or "") or "x86_64"
	end
	return arch_memo
end

--- URLs ativas dos repositórios configurados no xbps (xbps-query -L).
function M.repo_urls()
	local out = util.capture("xbps-query -L 2>/dev/null") or ""
	local urls, seen = {}, {}
	for line in out:gmatch("[^\r\n]+") do
		local u = line:match("(https?://%S+)")
		if u and not seen[u] then
			seen[u] = true
			urls[#urls + 1] = u
		end
	end
	return urls
end

-- parsing + cache --------------------------------------------------------

--- repodata do xbps = tar zstd-comprimido com 'index.plist'
-- (a mesma plist textual do pkgdb, um pacote por chave de 1 tab).
-- devolve caches = { sig=…, shlibs={soname=pkg}, provides={virtual=pkg} } | nil
local function parse_cache(path, cachef)
	local sig = util.file_sig(path)
	if not sig then return nil end
	local cached = util.load(cachef)
	if cached and cached.sig == sig and cached.shlibs then
		return cached -- cache hit: NENHUM zstd/tar/parse no caminho quente
	end
	local text = util.capture(
		("zstd -dc %s | tar -xOf - 'index.plist' 2>/dev/null"):format(esc(path)))
	if not text or text == "" then return nil end
	local _, shlibs, provides = prereq.scan_plist(text, "(?)")
	local maps = { sig = sig, shlibs = shlibs, provides = provides }
	util.makedirs(cachef:match("^(.*)/[^/]+$") or ".")
	util.save(maps, cachef)
	return maps
end

--- a ponte (v2.0): { shlibs={soname=pkg}, provides={virtual=pkg} } | nil.
-- nil = nenhum repodata nesta máquina: as camadas A/B da chain seguem com
-- o mapa INSTALADO (exatamente o comportamento da 1.2.1) — degradação
-- silenciosa, o lpm piora pra velho em vez de quebrar.
-- cache_root: onde a cópia/dump fica (default ~/.cache/lpm/void).
function M.bridge(cache_root)
	cache_root = util.expand_path(cache_root or "~/.cache/lpm/void")
	local urls = M.repo_urls()
	if #urls == 0 then return nil end
	local arch = M.host_arch()
	local shlibs, provides, any = {}, {}, false
	for _, url in ipairs(urls) do
		local rp = "/var/db/xbps/" .. safe(url) .. "/" .. arch .. "-repodata"
		if not util.file_exists(rp) then
			-- fallback: xbps da máquina nunca sincronizou. Baixa o MESMO
			-- arquivo que o xbps baixaria, via o downloader do lpm (sem
			-- sudo, como todo o resto).
			local cache_rdata = cache_root .. "/" .. safe(url) .. "-" .. arch .. ".repodata"
			if not util.file_exists(cache_rdata) then
				local fetch = require("lpm.fetch")
				util.makedirs(cache_root)
				fetch.download(url .. "/" .. arch .. "-repodata", cache_rdata)
			end
			if util.file_exists(cache_rdata) then rp = cache_rdata end
		end
		if util.file_exists(rp) then
			local maps = parse_cache(rp, cache_root .. "/" .. safe(url) .. ".lua")
			if maps then
				any = true
				for k, v in pairs(maps.shlibs) do
					if shlibs[k] == nil then shlibs[k] = v end
				end
				for k, v in pairs(maps.provides) do
					if provides[k] == nil then provides[k] = v end
				end
			end
		end
	end
	if not any then return nil end
	return { shlibs = shlibs, provides = provides }
end

return M
