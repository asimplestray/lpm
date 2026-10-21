-- lpm/detect.lua -- descobre em que tipo de sistema estamos.
--
-- Isto decide qual perfil de host usar. v0.1 suporta apenas Void; os outros
-- sistemas recebem mensagem clara do que falta e por que a ordem é essa.

local util = require("lpm.util")

local M = {}

--- lê /etc/os-release e devolve { ID=..., PRETTY_NAME=... }
function M.os_release()
	local text = util.read_file("/etc/os-release") or ""
	local info = {}
	for line in text:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then info[k] = (v:gsub('"', "")) end
	end
	return info
end

local sensors = {
	xbps = "xbps-install",
	dpkg = "dpkg-query",
	pacman = "pacman",
	rpm = "rpm",
}

--- id do PM nativo pelo binário encontrado no PATH
function M.detect_pm()
	for id, bin in pairs(sensors) do
		if util.which(bin) then return id end
	end
	return nil
end

--- retorna { os_id =, os_pretty =, pm =, profile = |nil, reason = |nil }
function M.detect()
	local rel = M.os_release()
	local pm = M.detect_pm()
	local os_id = (rel.ID or "desconhecido"):lower()
	if (os_id == "void" and pm == "xbps") then
		return { os_id = os_id, os_pretty = rel.PRETTY_NAME, pm = pm, profile = "void" }
	end
	local reason
	if os_id == "void" then
		reason = "the system is Void but xbps is not in PATH; lpm installs only through the host's native PM."
	else
		-- regra geral do projeto: o doador nunca é mais novo que o host.
		-- Void(rolling) <- Arch(rolling) é o par que funciona de verdade e é a
		-- v0.1; hosts Debian/Ubuntu procuram doadores MAIS VELHOS e entram
		-- depois.
		reason = ("no profile yet: host '%s' (%s). lpm 1.0 supports Void Linux."):format(
			os_id, rel.PRETTY_NAME or "?")
	end
	return { os_id = os_id, os_pretty = rel.PRETTY_NAME, pm = pm, profile = nil, reason = reason }
end

return M
