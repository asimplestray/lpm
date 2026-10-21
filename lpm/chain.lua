-- lpm/chain.lua
--
-- Cadeia de dependências (v0.3): quando uma dep do doador não está no
-- host, busca o provedor NO ÍNDICE DO DOADOR (nomes, provides e sonames)
-- e agenda a conversão dele também — a transação no host sai multi-pacote.
--
-- Regras que são do projeto, não da 0.3:
--   * conflito de VERSÃO (pacote do host existe porém velho) continua
--     BLOQUEADOR: substituir pacote nativo do host é decisão do usuário
--     (apenas o nome pedido no CLI entra como "update", com aviso);
--   * o doador nunca é mais novo que o host (a barreira pós-staging de
--     elf/preflight continua valendo por pacote, em qualquer profundidade);
--   * cada nó do plano diz por que entrou (caso for de depuração).
--
-- v1.2 — BOLHA PRIVADA (ideia do usuário): quando um soname do payload só
-- pode ser resolvido por um provedor do doador cujo NOME sombrearia um
-- pacote nativo do host, o plano continua com o provedor marcado como
-- PRIVADO: o payload dele não vira .xbps — entra DENTRO do pacote do app
-- (fold em /usr/lib/lpm/<pkg> + wrapper gerado; ver convert.lua). O
-- contexto pode recusar (ctx.allow_private = nil → aborta como antes).
-- Detalhes:
--   * a sub-cadeia INTEIRA de um provedor privado também é privada (nada
--     vaza no sistema por causa de uma lib privada);
--   * sonames com dissatisfação "bare" ('libffi.so') casam por PREFIXO com
--     as chaves do host ('libffi.so.8') — o versionamento do soname é a
--     marca de ABI (experiência real: cadêias do discord).
-- NOTA DE LÍNGUA: mensagens de issue chegam ao usuário → inglês.

local preflight = require("lpm.preflight")
local version = require("lpm.version")

local M = {}

local function provider_of(search, dep)
	local e = search(dep.name)
	if e then return e, ("dep '%s'"):format(dep.name) end
	if dep.name then
		local p = search(dep.name, true)
		if p then return p, ("provides of the donor '%s'"):format(dep.name) end
	end
	return nil, ("'%s' has neither a name nor provides/sonames in the donor index"):format(dep.name)
end

--- monta o plano para as entradas pedidas no CLI.
-- entries : { entry... } — os pedidos (primeiro do topo)
-- ctx     : {
--   search      = function(name, via_provides) -> entry|nil,
--   installed   = { nome = versão } do host,
--   shlibs      = { soname = pkg } do host | nil,
--   host_provides = { virtual = pkg } do host | nil, -- 'sh' do bash do Void
--   repo_shlibs   = { soname = pkg } do REPOSITÓRIO do host (v2.0) | nil,
--                   (repodata: satisfação por ponte mesmo sem a lib já
--                   instalada — o solver nativo puxa o pacote do repo)
--   repo_provides = { virtual = pkg } do repodata do host (v2.0) | nil,
--   donor_style = "pacman"/"deb",
--   host_style  = "xbps"/...
--   allow_private = true (v1.2): conflito de soname aceita bolha privada
-- }
-- opts    : { root_private = true } — entradas raiz ALSO privadas (usado
--           nas sub-planos da bolha: o provedor raiz NÃO pode virar tx,
--           senão o sistema nativo voltaria).
-- returns plan | nil, issues
-- plan = {
--   ordered       = { entry... } deep-first (provedores antes de quem os pede),
--   why           = { [pkg] = motivo da entrada },
--   issues        = { msgs } (duplicatas colapsadas),
--   private       = { [soname] = entry }   — resolvidos na bolha,
--   private_nodes = { [pkg] = entry }      — payloads que o fold vai baixar,
--   private_why   = { [pkg] = motivo },
--   solved        = { [dep] = host-pkg }   — v2.0: satisfeito POR PONTE
--                   (camadas A/B no mapa do host + repodata do host); o cli
--                   leva a tradução ao .xbps ('gtk3' → 'gtk+3' na dep),
--   ok            = true/false,
-- }
function M.plan(entries, ctx, opts)
	local plan = {
		ordered = {}, why = {}, issues = {}, ok = true,
		private = {}, private_nodes = {}, private_why = {},
		solved = {},
	}
	local issue_seen = {}
	local function add_issue(msg)
		-- mesmo bloqueador chega por dois caminhos de dep = mensagem idêntica
		-- (ex.: bitcoin/clazy em libs graficas): mostra UMA vez
		if not issue_seen[msg] then
			issue_seen[msg] = true
			table.insert(plan.issues, msg)
		end
	end
	local state = {} -- name -> true quando já no plano (tx OU privado)
	-- raiz = o que veio do CLI; a guarda de shadowing se aplica SÓ aos nós
	-- que a cadeia resolve (substituir nativo é decisão do usuário; o
	-- pedido EXPLÍCITO do CLI entra como update, com o aviso do cli.lua)
	local roots = {}
	for _, e in ipairs(entries) do roots[e.name] = true end

	-- soname satisfeito no host: match EXATO ou por PREFIXO ('libffi.so'
	-- bare casa com 'libffi.so.8' — o versing do soname marca a ABI).
	-- v2.0: primeiro o pkgdb INSTALADO (verdade de runtime), depois o
	-- repodata do repositório do host — satisfação por ponte vale
	-- MESMO SEM a lib instalada: o solver nativo puxa o pacote do repo
	-- como dep da transação (a dry-run é a última palavra).
	local function soname_satisfied(soname)
		if ctx.shlibs then
			local h = preflight.map_satisfies(ctx.shlibs, soname)
			if h then return h end
		end
		return ctx.repo_shlibs and preflight.map_satisfies(ctx.repo_shlibs, soname) or nil
	end

	local dfs          -- (entry, origem, priv?) -> bool
	local search_dep = function(e, dep, priv)
		-- depzin do doador: Debian qualifica arquitetura ('perl:any') —
		-- o 'any' não muda a resolução; strip ANTES de tudo
		if dep.name and dep.name:match(":any$") then
			dep = { name = dep.name:match("^(.-):any$"), op = dep.op, ver = dep.ver }
		end
		local canon = preflight.canonical(dep.name)
		local host_name = preflight.across(canon, ctx.host_style)
		local have = ctx.installed and (ctx.installed[dep.name] or ctx.installed[host_name])

		if dep.name:match("%.so") then
			-- soname: pkgdb do host primeiro; senão procura quem PROVIDEs o
			-- soname no doador (libisl → libisl.so=23-64). A conferência
			-- final é o check_elf pós-staging, com o mapa da transação.
			local have_s = soname_satisfied(dep.name)
			if have_s then return true end
			if priv or plan.private[dep.name] then
				return true -- resolvido na bolha; o fold pós-download entrega
			end
			local prov = provider_of(ctx.search, dep)
			if not prov then
				plan.ok = false
				add_issue(string.format(
					"%s: soname '%s' has no provider on the host nor in the donor %s",
					e.name, dep.name, not ctx.shlibs and "" or
					("(hint: lpm search '" .. dep.name:match("^(.-%.so)") .. "')")))
				return false
			end
			if ctx.shlibs then
				-- CLASH de nome: se o provedor do doador já existe no host, a
				-- transação o SUBSTITUIRÁ (update) — quebra os pacotes do host
				-- que pedem o soname NATIVO (ex.: bzip2 do Void provê
				-- libbz2.so.1, o do Arch libbz2.so.1.0). Regra central:
				-- substituir nativo é decisão do usuário.
				local prov_host = ctx.installed and
					(ctx.installed[prov.name] or
					ctx.installed[preflight.across(preflight.canonical(prov.name), ctx.host_style) or prov.name])
				if prov_host then
					if ctx.allow_private then
						-- v1.2: bolha privada — nada toca o sistema nativo
						plan.private[dep.name] = prov
						return dfs(prov, string.format(
							"provides of the donor '%s' (needed by %s)", dep.name, e.name), true)
					end
					plan.ok = false
					add_issue(string.format(
						"%s needs soname '%s' (donor's %s-%s), but '%s' already exists on the host (%s) — the transaction would replace it and break host packages that need the native soname; installing the donor over the native is the user's decision",
						e.name, dep.name, prov.name, prov.version, prov.name, prov_host))
					return false
				end
			end
			return dfs(prov, string.format("provides of the donor '%s' (needed by %s)", dep.name, e.name))
		elseif have then
			if dep.op and dep.ver then
				local oks, sat = pcall(version.satisfies, ctx.donor_style, have, dep.op, dep.ver)
				if not oks or not sat then
					plan.ok = false
					add_issue(string.format(
						"insufficient version: %s needs %s%s%s and the host has '%s' %s — solving by replacing the native package is the user's decision",
						e.name, dep.name, dep.op, dep.ver, host_name, have))
				end
			end
			return true
		elseif ctx.host_provides and ctx.host_provides[dep.name] then
			-- virtual provido no host (ex.: 'sh' do bash do VOID) — a versão
			-- do provide não é comparável entre línguas; vence como
			-- satisfeito (a conferência real é o dry-run do solver do host).
			return true
		elseif ctx.repo_provides and ctx.repo_provides[dep.name] then
			-- v2.0: virtual declarado no REPOSITÓRIO do host (provides do
			-- repodata). Sem tradução de nome: provide é matched nativamente
			-- pelo solver ('é a língua do próprio repodata).
			return true
		else
			-- camada A (aliasing automático): nome estilo Debian considera
			-- o soname comido — 'libssl3' → 'libssl.so.3' → se o host
			-- provê ESSA ABI sinalizada pelo soname, satisfeito. seguro por
			-- construção (só dispara com chave REAL no mapa do host) e
			-- dispensa tabela para a classe inteira de nomes lib<N>.
			-- com op de versão também dispara: a testemunha é ABI (a chave
			-- do soname), e a ÚLTIMA palavra sobre compat de versão é o
			-- scan do payload (elf: glibc_min do doador × host). o fluxo de
			-- deps sem testemunha segue igual (abort honesto).
			-- v2.0: o mapa pode ser o INSTALADO (pkgdb) ou o do REPOSITÓRIO
			-- (repodata); nos dois casos a dep some da conversão com o
			-- NOME do pacote do host anotado em plan.solved — é a tradução
			-- da linha de dep do .xbps ('gtk3' → 'gtk+3').
			local w = ctx.shlibs and preflight.deboname_satisfied(dep.name, ctx.shlibs)
			if not w and ctx.repo_shlibs then
				w = preflight.deboname_satisfied(dep.name, ctx.repo_shlibs)
			end
			if w then
				plan.solved[dep.name] = w
				return true
			end
		end

		-- não está no host: provedor no doador (recursão)
		local prov, motivo = provider_of(ctx.search, dep)
		if not prov then
			plan.ok = false
			add_issue(string.format(
				"%s: dep '%s' has no provider: %s", e.name, dep.name, motivo))
			return false
		end
		-- camada B (aliasing automático): o provedor do doador declara
		-- SONAMES e TODOS eles existem no host → é o MESMO componente com
		-- split igual (o caso 'libgl'→libglvnd): satisfeito pelo host, sem
		-- enfileirar conversão nenhuma. Provider sem sonames declarados
		-- (índice deb) não corrobora — nada automático nele.
		-- v2.0: o mapa pode ser o INSTALADO ou o do REPOSITÓRIO (repodata);
		-- comp = o host-pkg que provê os sonames → plan.solved traduz a dep
		local comp = preflight.host_component_pkg(prov, ctx.shlibs)
			or preflight.host_component_pkg(prov, ctx.repo_shlibs)
		if comp then
			plan.solved[dep.name] = comp
			return true
		end
		return dfs(prov, string.format("%s (needed by %s)", motivo, e.name), priv)
	end

	dfs = function(entry, origem, priv)
		if state[entry.name] then return true end
		-- guarda da regra central para nós NÃO-raiz FORA da bolha: um
		-- provedor do doador cujo nome já é pacote OU vpkg do host
		-- sombrearia o nativo (e o solver do xbps 0.60 trata
		-- vpkg-sombra como UPDATE do provider, perdendo os sonames dele:
		-- quirk reproduzido em 20/10/2026). DENTRO da bolha privada a
		-- guarda não se aplica: o payload não toca o sistema.
		--
		if not priv and not roots[entry.name] then
			local have = ctx.installed and
				(ctx.installed[entry.name] or
				ctx.installed[preflight.across(preflight.canonical(entry.name), ctx.host_style) or entry.name])
			local vpkg = ctx.host_provides and ctx.host_provides[entry.name]
			if have or vpkg then
				plan.ok = false
				add_issue(string.format(
					"'%s-%s' already exists on the host (%s) — the chain would convert it over the native; replacing the native is the user's decision",
					entry.name, entry.version,
					have and ("package '" .. entry.name .. "' " .. have) or
						("native vpkg '" .. entry.name .. "'")))
				return false
			end
		end
		state[entry.name] = true
		if priv then
			-- bolha: registrados em plan.private_nodes; o cli folda o
			-- payload DELES dentro do pacote do app (nada de .xbps)
			plan.private_nodes[entry.name] = entry
			plan.private_why[entry.name] = origem
		else
			plan.why[entry.name] = origem
		end
		for _, dep in ipairs(entry.depends or {}) do
			-- alternativa Debian ("a | b") já é reduzida no parser do doador
			search_dep(entry, dep, priv)
		end
		-- pós-ordem: provedores entram na ordem ANTES de quem os pede
		if not priv then
			plan.ordered[#plan.ordered + 1] = entry
		end
		return true
	end

	for _, e in ipairs(entries) do
		dfs(e, "requested on the CLI", opts and opts.root_private)
	end
	return plan
end

--- v2.0.5: nomes de pacote que PODEM prover um soname, derivados do próprio
-- soname. Isto é só um palpite de BUSCA no índice (libhspell.so.0 → hspell,
-- libhspell); a confirmação é o DT_SONAME do payload baixado — nunca o nome.
-- A ordem é determinística e o chamador decide se vale baixar cada candidato.
function M.provider_candidates(soname)
	if type(soname) ~= "string" then return {} end
	-- 'libhspell.so.0' → base 'libhspell.so'; sem '.so' não há o que derivar
	local base = soname:match("^(.-%.so)%.[%d%.]+$") or soname
	if not base:match("%.so$") then return {} end
	local stem = base:gsub("%.so$", "")
	local out, seen = {}, {}
	local function add(n)
		if n and #n >= 2 and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	add(stem)
	local no_lib = stem:match("^lib(.+)$")
	if no_lib then
		add(no_lib)
		-- variação comum de nome de pacote: 'gtk-3' ↔ 'gtk3'
		if no_lib:find("-", 1, true) then
			add((no_lib:gsub("%-", "")))
		end
	end
	-- convenção Debian de empacotar a ABI no nome: libssl.so.3 → libssl3,
	-- libhspell.so.0 → libhspell0. Continua sendo só nome de busca.
	local major = soname:match("%.so%.(%d+)")
	if major then
		add(stem .. major)
		add(stem .. "-" .. major)   -- libgtk-3.so.0 → libgtk-3-0
		if no_lib then
			add(no_lib .. major)    -- libhspell.so.0 → hspell0
			add(no_lib .. "-" .. major)
		end
	end
	return out
end

return M
