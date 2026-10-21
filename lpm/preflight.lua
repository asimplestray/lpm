-- lpm/preflight.lua
--
-- Pré-conferência: dado um pacote doador, ele cabe no HOST? A regra central
-- do projeto: NADA é baixado/instalado antes do preflight dizer claramente
-- o que falta. Falhar cedo e com razão específica, em vez de instalar quebrado
-- e deixar o usuário descobrir num segfault depois.
--
-- v0.1 checa NOME e, com versão pedida, versão; o passo seguinte é checar
-- sonames reais lendo DT_NEEDED do binário (TODO).

local version = require("lpm.version")
local aliases = require("lpm.aliases")

local M = {}

--- resolve o nome canônico: "glibc" e "libc6" são o MESMO componente.
-- retorna o próprio nome quando não há registro (nomes comuns batem direto).
function M.canonical(name)
	for canon, alts in pairs(aliases) do
		for _, vname in pairs(alts) do
			if vname == name then return canon end
		end
	end
	return name
end

--- nome do componente canônico em outro mundo (pacman / deb / xbps)
function M.across(canon_or_name, style)
	local alts = aliases[canon_or_name]
	if alts and alts[style] then return alts[style] end
	return canon_or_name
end

--- dep de sonome do doador ("libisl.so=23-64") → soname real.
-- Convenção do pacman: soname=MAJOR-ABI ("23-64": o 64 é marcação de
-- largura e não entra no soname que o host realmente provê).
function M.soname_of(dep)
	local name = dep.name or ""
	if not name:match("%.so") then return name end
	if dep.op == "=" and dep.ver then
		local maj = dep.ver:gsub("%-.*", "")
		if maj ~= "" then return name .. "." .. maj end
	end
	return name
end

--- soname satisfeito num mapa { soname = pkg }: EXATO ou por prefixo.
-- dep bare 'libffi.so' casa com a chave do host 'libffi.so.8' — o
-- número no soname é a marca de ABI, mais nova no host é o caso normal
-- (experiência real: discord puxava libffi.so e o host só tem .so.8).
-- v1.2: compartilhado com chain.lua.
function M.map_satisfies(shlibs, soname)
	if not shlibs then return nil end
	if shlibs[soname] then return shlibs[soname] end
	for k, v in pairs(shlibs) do
		if k:sub(1, #soname + 1) == soname .. "." then return v end
	end
	return nil
end

-- ALIASING AUTOMÁTICO (v1.2.1 — pedido do usuário: a tabela manual é
-- ineficiente). Duas fontes de verdade já existem — o mapa de sonames do
-- host e o índice do doador — e a maioria dos "aliases" delas deriva SEM
-- tabela: um nome é só uma consequência de QUAL soname o pacote carrega.
-- A lpm/aliases.lua vira override para exceções documentadas.

--- nome de pacote estilo Debian → soname reconstruído (ou nil).
-- Debian nomera libs de shlib como 'lib<stem>.so.<major>' com pontuação
-- comida: libc6 → libc.so.6, libssl3 → libssl.so.3, libgcc-s1 →
-- libgcc-s.so.1, libsqlite3-0 → libsqlite3.so.0, libatk-1.0-0 →
-- libatk-1.0.so.0. A RECONSTRUÇÃO NÃO É A VERDADE — só é usada se o
-- soname candidato existir no mapa do host (aí a satisfação é real por
-- construção: o host provê exatamente aquela ABI).
function M.deboname_soname(name)
	if type(name) ~= "string" or not name:match("^lib") or name:match("%.so") then
		return nil
	end
	-- suffixo '-N' (SONAME major com hífen preservado): libsqlite3-0,
	-- libatk-1.0-0 (stem guarda '1.0' — é parte do nome do soname)
	local stem, major = name:match("^lib(.+)%-(%d+)$")
	if stem == "" then return nil end
	if not stem then
		-- sem hífen: dígitos finais = major. libssl3, libc6, libgcc-s1
		local head, digits = name:match("^lib(.+)(%d+)$")
		if not head then return nil end
		-- 'liblua5.4' viraria 'liblua5..so.4' → sem sentido; stem tem que
		-- terminar em letra/dígito limpo, não em pontuação
		if not head:match("[%w%+%-]$") then return nil end
		stem, major = head, digits
	end
	return "lib" .. stem .. ".so." .. major
end

--- satisfação AUTOMÁTICA por reconstrução: dep 'libssl3' → soname
-- 'libssl.so.3' → se o host prove (exato, por prefixo ou normalizado —
-- 'libgcc_s.so.1' × 'libgcc-s.so.1' só differem de pontuação), o dep já
-- está satisfeito. devolve o pacote do host | nil.
function M.deboname_satisfied(name, shlibs)
	local cand = M.deboname_soname(name)
	if not cand or not shlibs then return nil end
	local have = M.map_satisfies(shlibs, cand)
	if have then return have end
	-- pontuação: Debian come separadores do nome do pacote e o SONAME
	-- real pode ter '-' onde o nome tem nada (libgcc-s1 → libgcc_s.so.1)
	local function norm(s)
		return (s:lower():gsub("[%-%._%+]", ""))
	end
	local nc = norm(cand)
	for k, v in pairs(shlibs) do
		local nk = norm(k)
		if nk == nc or nk:sub(1, #nc + 1) == nc .. "." then return v end
	end
	return nil
end

--- corroboração por soname do PROVEDOR (camada B): dep virtual 'libgl'
-- → quem provides no doador é 'libglvnd', que declara os SONAMES dele;
-- se TODOS os sonames declarados existem no mapa do host, o componente
-- é O MESMO nos dois mundos → satisfeito pelo host, sem converter nada.
-- (se só alguns existem, o split de pacotes difere — não dá pra provar,
-- e aí NADA é automático: cai no fluxo normal, que sabe abortar honesto.)
function M.provider_sonames_on_host(prov, shlibs)
	-- v2.0: devolve O NOME do host-pkg (era a última testemunha antes de
	-- host_component_pkg assumir a maioria) — mesmo valor de sempre
	return M.host_component_pkg(prov, shlibs)
end

--- quem no host "é" o provedor do doador (v2.0): o host-pkg que provê a
-- MAIORIA dos sonames declarados, com TODOS eles presentes no mapa
-- (um soname fora = split de pacotes diferente → nada automático).
-- devolve o NOME do host-pkg | nil. Empate de maioria → o menor nome
-- (determinismo: mesmo plano repetido nunca diverge).
function M.host_component_pkg(prov, shlibs)
	if not prov or not shlibs then return nil end
	local count, total = {}, 0
	for _, raw in ipairs(prov.provides or {}) do
		-- o formato de provides varia com o repositório: arch guarda STRING
		-- crua ('libGL.so=1-7'), fixtures/convert usam {name=...} — normalizo
		local pd = (type(raw) == "string") and version.parse_dep(raw) or raw
		local n = (type(pd) == "table" and pd.name) or raw
		n = n or ""
		if n:match("%.so") then
			local h = M.map_satisfies(shlibs, n)
			if not h then
				return nil -- um soname do provedor fora do host = split diferente
			end
			count[h] = (count[h] or 0) + 1
			total = total + 1
		end
	end
	if total == 0 then return nil end
	local best, best_n, best_c
	for name, c in pairs(count) do
		if not best or c > best_c or (c == best_c and name < best) then
			best, best_n, best_c = name, name, c
		end
	end
	return best or best_n
end

--- confere as DEPENDS de uma entrada do doador contra o o que o host tem.
-- entry      : de lpm/repos (entry.depends = { name=, op=, ver= })
-- pm_installed: mapa do host { nome = versão }
-- donor_style: língua de versão do doador ("pacman" / "deb")
-- shlibs     (opcional): mapa { soname = pkgname } do host
--             (pm.shlib_provides()); com ele, soname-dep passa de aviso
--             a checagem REAL: sem provedor no host = bloqueio.
-- repo       (opcional, v2.0): { shlibs=(...), provides=(...) } do
--             repodata do host — mesmas camadas A/B, no plano do repo
-- returns ok(bool), issues(list de strings)
function M.check_deps(entry, pm_installed, donor_style, host_style, shlibs, repo)
	local ok = true
	local issues = {}
	local repo_shlibs = repo and repo.shlibs or nil
	for _, dep in ipairs(entry.depends or {}) do
		if (dep.name or ""):match("%.so") then
			-- dep de soname: com o mapa de shlibs do host é um bloqueio real
			-- (é o caso declarado do doador); sem mapa, fica o aviso da v0.1.
			local soname = M.soname_of(dep)
			local have_s = shlibs and M.map_satisfies(shlibs, soname) or nil
			if not have_s and repo_shlibs then
				have_s = M.map_satisfies(repo_shlibs, soname)
			end
			if have_s then
				-- provido — ok silencioso
			elseif shlibs or repo_shlibs then
				ok = false
				table.insert(issues, string.format(
					"unresolved: %s declares soname '%s' — the host does not provide '%s' (install its provider first; try: lpm search '%s')",
					entry.name, dep.name .. (dep.op or "") .. (dep.ver or ""),
					soname, ((soname:gsub("%.so.*$", "")):gsub("^lib", ""))))
			else
				table.insert(issues, string.format(
					"soname warning: %s declares '%s%s%s' — check manually (no shlib map on this PM)",
					entry.name, dep.name, dep.op or "", dep.ver or ""))
			end
		else
			-- primeira chance: mesmo nome no host (arch e xbps costumam bater)
			local canon = M.canonical(dep.name)
			local host_name = M.across(canon, host_style)
			local have = pm_installed[dep.name] or pm_installed[host_name]
			-- aliasing automático (v1.2.1): nome 'libssl3' reconstrói o
			-- soname 'libssl.so.3'; se o host provê ESSA ABI, satisfeito
			-- (mesma verificação do chain.plan — conferências iguais nos
			-- dois estágios, ou o check mente sobre o install)
			local auto = not have and M.deboname_satisfied(dep.name, shlibs)
			if not auto and repo_shlibs then
				auto = M.deboname_satisfied(dep.name, repo_shlibs)
			end
			if not auto and repo and repo.provides and repo.provides[dep.name] then
				-- v2.0: virtual do repodata do host — o solver nativo casa
				auto = repo.provides[dep.name]
			end
			if not have and not auto then
				ok = false
				table.insert(issues, string.format(
					"unresolved: %s needs '%s'%s — none of '%s'/'%s' is installed on the host (the chain pass in `lpm install` may still rescue it from the donor)",
					entry.name, dep.name, dep.ver and dep.op .. dep.ver or "", dep.name, host_name))
			elseif dep.op and dep.ver then
				-- a restrição é da língua do DOADOR; comparar versão do host na
				-- língua do doador funciona nos casos comuns porque os formatos
				-- xbps/pacman são próximos (epoch:ver[_rev]). TODO: tradução
				-- cross-format completa com checagem duplicada no host.
				local okc, sat = pcall(version.satisfies, donor_style, have, dep.op, dep.ver)
				if not okc then
					ok = false
					table.insert(issues, string.format(
						"version error: %s wants %s%s%s; comparing '%s' x '%s' failed: %s",
						entry.name, dep.name, dep.op, dep.ver, have, dep.ver, tostring(sat)))
				elseif not sat then
					ok = false
					table.insert(issues, string.format(
						"insufficient version: %s needs %s%s%s, the host has %s (%s)",
						entry.name, dep.name, dep.op, dep.ver, host_name, have))
				end
			end
		end
	end
	return ok, issues
end

--- confere o CARGO REAL do payload (resultado de elf.scan) contra o host.
-- Duas barreiras, nesta ordem:
--   1. glibc: o máximo GLIBC_ exigido dos binários não pode ser maior que
--      a glibc instalada — é a regra central ("doador nunca é mais novo
--      que o host") tornado fato por pacote. Sem versão do host para
--      conferir, vira aviso (o solver do host ainda pegará na dry-run).
--   2. sonames do payload (DT_NEEDED): cada um precisa de provedor no
--      pkgdb do host, à exceção do que o próprio payload provê (DT_SONAME).
-- Payload sem NENHUM ELF (pacote de scripts, dados) é caso legítimo:
-- aviso, não bloqueio — não há ABI a conferir.
-- v2.0: repo_shlibs (repodata do host) é o ÚLTIMO recurso do mapeamento —
-- soname que o POOL resolve (pacote nativo que o próprio solver puxará
-- como dep) não é bloqueio; fica anotado para transparência. A bolha
-- privada '*' e as marcas da transação continuam à FRENTE do repo.
-- returns ok(bool), bloqueios(list), avisos(list), resolvidos(list)
function M.check_elf(name, scan, shlibs, host_glibc_ver, repo_shlibs)
	local ok = true
	local bloqueios, avisos, resolvidos = {}, {}, {}

	if not scan then return true, {}, {}, {} end

	if scan.elf == 0 then
		table.insert(avisos, string.format(
			"the payload of %s has no ELF at all (scripts/data?) — nothing to ABI-check", name))
		return true, {}, avisos, resolvidos
	end

	-- glibc (comparação na língua do HOST: dewey do xbps)
	if scan.glibc_min then
		if not host_glibc_ver then
			table.insert(avisos, string.format(
				"ABI: the payload of %s requires glibc %s but the host glibc version is unknown — leaving it to the host dry-run",
				name, scan.glibc_min))
		elseif version.xbps_cmp(scan.glibc_min, host_glibc_ver) > 0 then
			ok = false
			table.insert(bloqueios, string.format(
				"ABI: %s (the donor is newer than the host) — the binaries require glibc %s, the host has %s: do not install this",
				name, scan.glibc_min, host_glibc_ver))
		end
	end

	for _, s in ipairs(scan.needed_names or {}) do
		if scan.self and scan.self[s] then
			-- o próprio payload provê; não é do host
		else
			local have = shlibs and M.map_satisfies(shlibs, s) or nil
			local via_repo = false
			if not have and repo_shlibs then
				have = M.map_satisfies(repo_shlibs, s)
				via_repo = have ~= nil
			end
			if have then
				resolvidos[#resolvidos + 1] = s .. " → " .. (via_repo and ("repo:" .. have) or have)
			else
				ok = false
				table.insert(bloqueios, string.format(
					"soname: %s needs '%s', which the host does not provide (search for providers: lpm search '%s')",
					name, s, s:gsub("%-%d+$", ""):gsub("%.so.*$", "")))
			end
		end
	end
	return ok, bloqueios, avisos, resolvidos
end

return M
