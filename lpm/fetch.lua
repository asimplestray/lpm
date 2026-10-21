-- lpm/fetch.lua -- download de arquivos via subprocesso.
-- xbps-fetch (presente em qualquer Void) é a preferência; curl e wget servem
-- de plano B para o resto. Sem bindings HTTP em Lua: toda distro alvo terá um
-- destes binários, e curl -f (--fail) garante que erros HTTP não gravem
-- páginas de erro como se fosse o arquivo.

local util = require("lpm.util")
local M = {}

local sh = util.sh
local which = util.which

--- baixa url para dest. Retorna true|nil, msg.
function M.download(url, dest)
	local fetcher = which("xbps-fetch", "curl", "wget")
	local cmd
	if not fetcher then
		return nil, "no downloader found (I need xbps-fetch, curl or wget)"
	end
	if fetcher:match("curl$") then
		cmd = string.format("curl -fsSL --retry 2 -o '%s' '%s'", dest, url)
	elseif fetcher:match("wget$") then
		cmd = string.format("wget -q -O '%s' '%s'", dest, url)
	else
		-- xbps-fetch é quieto por padrão (progresso vem stderr e nem sempre
		-- aparece); curl/wget recebem os flags de quiet próprios
		cmd = string.format("xbps-fetch -o '%s' '%s'", dest, url)
	end
	local code = sh(cmd)
	if code ~= 0 then
		os.remove(dest) -- não deixa arquivo truncado no cache
		return nil, "download failed (" .. tostring(code) .. "): " .. url
	end
	return true
end

return M
