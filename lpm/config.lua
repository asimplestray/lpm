-- lpm/config.lua -- configuração do usuário sobrepõe defaults do perfil.
-- ~/.config/lpm/config.lua é um arquivo Lua normal:  return { mirror = "..." }
-- v1.1: troca de espelho por chave (mirrors = { arch = "...​", debian = "..." })
-- e flag --mirror na CLI; o caminho atrás da base é propriedade DO PERFIL.

local util = require("lpm.util")

local M = {}

function M.load(profile)
	local cfg = {
		db_dir = profile and profile.donor and profile.donor.db_dir
			or "~/.cache/lpm/arch",
		install_repo_dir = profile and profile.install_repo_dir or "~/.cache/lpm/converted",
		dry_default = profile and profile.dry_default ~= false,
		-- troca de espelho POR DOADOR (v1.1): { arch = "https://…/archlinux" }
		mirrors = {},
	}

	local path = util.expand_path("~/.config/lpm/config.lua")
	if not util.file_exists(path) then
		return cfg
	end
	local chunk = loadfile(path, "t")
	if not chunk then
		error("syntax error in ~/.config/lpm/config.lua")
	end
	local ok, user = pcall(chunk)
	if not ok then error("config ~/.config/lpm/config.lua: " .. tostring(user)) end
	if type(user) == "table" then
		for k, v in pairs(user) do
			cfg[k] = v
		end
	end

	-- nota de design: nada aqui pode trocar o DOADOR por um mais novo que o
	-- host; isso é regra do projeto (alias na doc), não preferência de config.
	return cfg
end

--- troca a base (espelho) de um doador e REENCADEIA as urls. Puro e
-- conforme para teste; donor_of (cli) decide quem chama.
-- donor : { mirror="http…", repos = { { id=…, path="/…" } | { id=…, url=… } },
--           file_url_template = "%MIRROR%/…" | "http…/…" }
-- base  : nova base ("https://mirror…/archlinux") ou nil → usa donor.mirror
-- retorna cópia nova (o perfil NUNCA é mutado) | nil, msg
function M.apply_mirror(donor, base)
	if type(base) == "string" and base ~= "" then
		base = base:gsub("/+$", "") -- sem barra final (o path já a traz)
		if not base:match("^https?://") then
			return nil, "mirror override must start with http(s):// (got '"
				.. base .. "')"
		end
	else
		base = donor.mirror
	end
	if type(base) ~= "string" or base == "" then
		return nil, "donor '" .. tostring(donor.id or "?") .. "' has no mirror base"
	end
	local nd = {}
	for k, v in pairs(donor) do nd[k] = v end
	nd.mirror = base
	nd.repos = {}
	for i, r in ipairs(donor.repos or {}) do
		if r.path then
			nd.repos[i] = { id = r.id, path = r.path, url = base .. r.path }
		elseif r.url then
			-- forma legada do perfil (url absoluta): só aceita se a base
			-- declarada do doador ainda é prefixo dela
			if donor.mirror and r.url:sub(1, #donor.mirror + 1) ~= donor.mirror .. "/" then
				return nil, "repo '" .. tostring(r.id) .. "' url does not match donor mirror base"
			end
			nd.repos[i] = { id = r.id, path = r.url:sub(#base + 1), url = base .. r.url:sub(#donor.mirror + 1) }
		else
			return nil, "repo #" .. tostring(i) .. " has neither path nor url"
		end
	end
	return nd
end

return M
