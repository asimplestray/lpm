-- lpm/pm/dpkg.lua -- adaptador dpkg/apt (host Debian/Ubuntu; doador futuro).

local util = require("lpm.util")

local M = {}
M.id = "dpkg"

--- mapa { nome = versão } dos pacotes instalados.
function M.installed()
	local map = {}
	local out = util.capture(
		"dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\\n' 2>/dev/null") or ""
	for line in out:gmatch("[^\r\n]+") do
		-- "ii <nome> <versão>"; linhas de remoção pendente ("rc") são lixo
		local st, name, ver = line:match("^(%S+)%s+(%S+)%s+(%S+)")
		if st and st:match("^ii") and name then
			map[name] = ver
		end
	end
	return map
end

M.install_cmd = "apt-get"
M.install_repo_flag = nil

return M
