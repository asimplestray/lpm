-- lpm/convert.lua
--
-- Conversão de pacote doador (pacman .pkg.tar.zst) em pacote do host (.xbps).
--
-- O que a v0.1 FAZ (seguro e verificável):
--   1. baixa o pacote do doador;
--   2. confere sha256 contra o registrado no índice;
--   3. extrai o payload para staging IGNORANDO os scripts e metadados do
--      doador (.INSTALL/.PKGINFO/.MTREE/.BUILDINFO) — os scripts do Arch
--      falam de systemctl e Void é runit; scripts de distro doadora nunca
--      rodam no host;
--   4. executa a conversão SEM ROOT: xbps-create com flags validadas contra
--      o `--help` do host, xbps-rindex para registrar o .xbps no repósito
--      local, e o dry-run `xbps-install -n` para o solver do host conferir
--      a transação ANTES de qualquer instalação.
--
-- O passo que exige root (`sudo xbps-install`) nunca é executado pelo lpm:
-- o comando exato é impresso para o usuário decidir.

local util = require("lpm.util")
local fetch = require("lpm.fetch")
local preflight = require("lpm.preflight")
local version = require("lpm.version")

local function esc(s)
	return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local M = {}

function M.verify_sha256(path, expected)
	local out = util.capture("sha256sum '" .. path .. "' 2>/dev/null")
	local have = out and out:match("^(%x+)%s")
	return have == expected
end

--- baixa o pacote do doador para o cache e confere o sha256.
-- retorna caminho do arquivo | nil, msg
function M.acquire(entry, profile, cfg, donor)
	local d = donor or profile.donor
	local db_dir = util.expand_path(d.db_dir or cfg.db_dir)
	local dest = db_dir .. "/" .. entry.filename
	-- Filename do doador pode trazer subpastas (Debian: pool/main/x/…)
	util.makedirs(db_dir .. "/" .. (entry.filename:match("^(.*)/[^/]+$") or "."))

	if util.file_exists(dest) and entry.sha256 and M.verify_sha256(dest, entry.sha256) then
		return dest -- cache hit
	end

	-- v1.1: %MIRROR% primeiro (a base que apply_mirror acabou de trocar);
	-- depois %REPO%/%FILENAME% que dependem apenas do índice
	local url = d.file_url_template
		:gsub("%%MIRROR%%", d.mirror)
		:gsub("%%REPO%%", entry.repo)
		:gsub("%%FILENAME%%", entry.filename)

	if util.file_exists(dest) then
		-- cache com sha256 divergente: baixa de novo, o índice é a verdade
		os.remove(dest)
	end
	local ok, err = fetch.download(url, dest)
	if not ok then return nil, err end

	if entry.sha256 and not M.verify_sha256(dest, entry.sha256) then
		os.remove(dest)
		return nil, "sha256 mismatch for " .. entry.filename .. " (suspicious mirror?)"
	end
	return dest
end

--- extrai payload para o campo staging (sem .INSTALL/.PKGINFO/.MTREE/.BUILDINFO)
-- os metadados do doador têm nomes na RAIZ do tar (".PKGINFO", sem './'),
-- então o padrão de exclude não leva o prefixo; por garantia o lpm também
-- remove esses arquivos do staging depois da extração.
local STAGE_DROPS = { ".INSTALL", ".PKGINFO", ".MTREE", ".BUILDINFO" }

function M.stage(pkg_path, staging_dir, donor)
	local d = donor or { stage_style = nil }
	-- doador com payload em .deb (ar): o módulo dele sabe extrair e usa as
	-- MESMAS regras (só payload, scripts ignorados)
	if d.stage_style == "deb" or pkg_path:match("%.deb$") then
		util.makedirs(staging_dir)
		return require("lpm.repos.debian").stage(pkg_path, staging_dir)
	end
	util.makedirs(staging_dir)
	local excl = {}
	local rms = {}
	for _, e in ipairs(STAGE_DROPS) do
		excl[#excl + 1] = "--exclude=" .. esc(e)
		rms[#rms + 1] = "rm -f " .. esc(staging_dir .. "/" .. e)
	end
	local cmd = string.format("tar -xf %s -C %s %s", esc(pkg_path), esc(staging_dir),
		table.concat(excl, " "))
	if util.sh(cmd .. " && " .. table.concat(rms, " && ")) ~= 0 then
		return nil, "payload extraction failed: " .. pkg_path
	end
	return staging_dir
end

-- conversão automática (sem root) ----------------------------------------

-- flags do xbps-create que o lpm usa; todas precisam aparecer no --help do
-- host ou a conversão é abortada (flag de ferramenta externa não se adivinha).
local CREATE_FLAGS = { "-n", "-s", "-A", "-l", "-H", "-D", "-P" }

--- traduz versão do doador p/ língua xbps (empírico no host real, v0.3):
-- o xbps aceita alnum, '.', '~' e ':' (epoch) e UM ÚNICO '_' (revisão final).
-- '-' e '+' (Debian '3.03+dfsg2-8', Arch '16.2.1+r23+g…') viram '.'; se a
-- versão não terminar em revisão '_<n>', completo com '_1'. O doador é a
-- referência de orderedness pro version.satisfies — a tradução é só P/NOME.
function M.version_to_xbps(ver)
	ver = ver:gsub("[^%w%.%~:%-]", ".") -- limpa tudo que não é xbps-legal
	ver = ver:gsub("%-", ".") -- '1.2-3' → '1.2.3' (rev '-' não existe aqui)
	if not ver:match("_[%d]+$") then ver = ver .. "_1" end -- revisão xbps
	return ver
end

--- converte versão do doador para pkgver no formato xbps.
-- Epoch 'N:' fica como está (o comparador do xbps lida com ele); o resto
-- passa por version_to_xbps (o '_' não é usado internamente pois a revisão
-- final é garantida ali).
function M.host_pkgver(entry)
	return entry.name .. "-" .. M.version_to_xbps(entry.version)
end

--- arch efetivo NO POOL LOCAL (v2.0): o xbps-rindex 0.60 recusa .xbps de
-- arch 'any' ("ignoring …, unmatched arch (any)") — os repositórios do
-- Void indexam any pelo pipeline deles, mas o nosso pool é por máquina.
-- um .xbps 'any' do doador é consumível por TODOS os archs (é isso que a
-- marca quer dizer), então no pool local ele CASA com o arch do host.
function M.pool_arch(entry)
	local a = entry.arch or ""
	if a == "" or a == "any" or a == "noarch" then return "x86_64" end
	return a
end

--- escapa metacaracteres de pattern Lua (nomes de pkg têm '-' e '.').

local function esc_pattern(s)
	return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

--- versões .xbps do MESMO nome+arch que NÃO são a candidata atual
-- (o repodata é chaveado por nome; o arquivo velho é lixo de espaço e
-- confunde a leitura do 'lpm list').
function M.stale_versions(repo_dir, name, arch, keep_pkgver)
	local out = util.capture("ls -1 '" .. repo_dir .. "' 2>/dev/null")
	local st = {}
	local pat = "^" .. esc_pattern(name) .. "%-(.+)$"
	for file in out:gmatch("[^%s]+") do
		local pv, fa = file:match("^(.+)%.(%w[%w_]*)%.xbps$")
		if fa == arch and pv then
			local ver = pv:match(pat)
			if ver and (name .. "-" .. ver) ~= keep_pkgver then
				st[#st + 1] = { path = repo_dir .. "/" .. file, pkgver = name .. "-" .. ver }
			end
		end
	end
	return st
end

function M._check_create_tool()
	if not util.which("xbps-create") then
		return nil, "xbps-create is not in PATH (void package: xbps, should be preinstalled)"
	end
	local help, code = util.capture("xbps-create --help 2>&1")
	if code ~= 0 or help == "" then
		return nil, "xbps-create --help failed; cannot validate flags"
	end
	local missing = {}
	for _, f in ipairs(CREATE_FLAGS) do
		if not help:find(f, 1, true) then missing[#missing + 1] = f end
	end
	if #missing > 0 then
		return nil, "this xbps-create does not support: " .. table.concat(missing, " ")
	end
	return true
end

--- dependências em LÍNGUA XBPS para o -D do xbps-create.
-- soname-deps (libisl.so=23-64) são omitidos: quem os resolve no v0.1 é o
-- preflight (aviso) e a resolução correta por provides é do v0.2.
--
-- Regra empírica (confirmada no host real com dry-run `xbps-install -n`):
-- o solver de transação do xbps EXIGE restrição de versão na dep —
-- 'glibc' pelado quebra com "can't guess pkgname for dependency 'glibc'",
-- 'glibc>=2.38' e 'glibc>=2.38_1' e 'glibc>=0' resolvem. Dep do doador sem
-- versão declarada vira `>=0` (piso: existe qualquer versão).
--
-- v2.0 — TRADUÇÃO DE NOME em camadas (na ordem):
--   1. tx.solved — o que a CADEIA provou no plano (camada A/B sobre o
--      pkgdb INSTALADO ou o repodata do host): 'gtk3' → 'gtk+3';
--   2. tabela de exceções (aliases.lua across);
--   3. testemunha de soname no mapa da TRANSACÃO (tx_shlibs, que pode
--      marcar '(*)' — bolha privada — e aí a dep SOME);
--   4. repodata do host (tx.repo_shlibs) — último recurso, sem marca.
function M.host_deps(entry, host_style, host_shlibs, solved, repo_shlibs)
	local out = {}
	for _, dep in ipairs(entry.depends or {}) do
		if not (dep.name or ""):match("%.so") then
			-- strip de qualificador Debian ('perl:any'): o 'any' não existe
			-- no idioma do xbps
			local eff_name = dep.name:match("^(.-):%w+$") or dep.name
			-- 'sh' do doador é a dep de /bin/sh — o Void não a expressa
			-- como vpkg cru (a provide do dash é 'cmd:sh-0_1' e o solver
			-- não casa 'sh>=0' — MISSING puro). Todo host Unix tem /bin/sh:
			-- a dep é meta, DROP
			if eff_name == "sh" then
				goto continue
			end
			local canon = preflight.canonical(eff_name)
			local name = preflight.across(canon, host_style)
			-- v2.0 camada 1: o plano JÁ provou quem satisfaz esta dep
			-- (pkgdb instalado ou repodata do host) — a tradução é a
			-- linha de dep do .xbps entregando o NOME NATIVO
			if solved and solved[eff_name] and name == eff_name then
				name = solved[eff_name]
			else
			-- aliasing automático (v1.2.1): se a tabela não traduz (nome ==
			-- doador), o soname reconstruído decide QUEM no host provê
			-- aquela ABI e a dep sai no NOME DO HOST ('libc6' → 'glibc').
			-- marcador '(*)' = resolvido na bolha privada → a dep some do
			-- .xbps (o payload da lib está DENTRO do pacote, não é dep).
				if name == eff_name and host_shlibs then
					local witness = preflight.deboname_satisfied(eff_name, host_shlibs)
					if witness and witness:find("(*", 1, true) then
						goto continue -- privado: não é dep do sistema
					elseif witness and not witness:find("%?", 1, true) then
						name = witness
					end
				end
				-- camada 4: repodata do host — o POOL tem um pacote para
				-- essa ABI; o solver nativo o puxará como dep
				if name == eff_name and repo_shlibs then
					local hit = preflight.deboname_satisfied(eff_name, repo_shlibs)
					if hit then name = hit end
				end
			end
			-- versão do doador na língua xbps: '-' e '+' viram '.', revisão
			-- garantida (mesma tradução do pkgver) — Debian '3.03+dfsg2-8'
			-- e Arch '16.2.1+r23+g…' não engolem cru
			local ver = dep.ver and M.version_to_xbps(dep.ver) or nil
			if dep.op and dep.ver then
				out[#out + 1] = name .. dep.op .. ver
			elseif ver then
				out[#out + 1] = name .. ">=" .. ver
			else
				out[#out + 1] = name .. ">=0"
			end
		end
		::continue::
	end
	return out
end

--- reescreve a dep do solver quando quem satisfaz está NA transação:
-- 1) dep de um pkg que outro nó converte → DEP EXATA em formato pkgver
--    ('perl-base-5.40.1.6.deb13u1_1'): match direto no repo local, sem
--    corrida de versão contra repo remoto (o solver escolhe a MAIOR
--    versão de todo o pool — um repo remoto venceria errado);
-- 2) dep virtual que outro nó provê por -P → dep exata do provider
--    (solve-by-vpkg-de-repo-local deixa o solver a checar shlibs como
--    UPDATE do vpkg no host e lose os sonames do pacote nativo — quirk
--    do xbps 0.60, reproduzido fora do lpm);
-- 3) 'nome=pkgver' NÃO casa no xbps (empírico: 'perl-base=5.40...' →
--    not found) — o formato do pkgver completo é a dep exata dele.
-- Sonames (<%.so>) passam por aqui intactos.
function M.rewrite_dep(dep, tx, self_name)
	if not tx then return dep end
	local nm = dep:match("^([^%[<>=~%s]+)") or dep
	nm = nm:match("^(.-):%w+$") or nm
	if nm == self_name then return dep end
	local ver = tx.pkgver[nm]
	if ver then return nm .. "-" .. ver end
	local provider = tx.vpkg[nm]
	if provider and tx.pkgver[provider] then
		return provider .. "-" .. tx.pkgver[provider]
	end
	return dep
end

-- bolha privada (v1.2) ------------------------------------------------------
--
-- A ideia do usuário: quando a única lib que fecha a transação sombrearia
-- um pacote nativo do host, ela NÃO entra no sistema — o payload dela é
-- copiado para /usr/lib/lpm/<pkg>/ DENTRO do pacote do app, e um wrapper
-- gerado aponta o LD_LIBRARY_PATH do processo do app para lá. Resultado:
-- um .xbps só, um sudo só, desinstalação limpa pelo xbps (as libs são
-- arquivos do pacote), e a lib nativa do host intocada.

--- copia os payloads privados para o staging do app e devolve os caminhos
-- RELATIVOS (/usr/lib/lpm/<pkg>) na ordem de preferência. ordem importa:
-- no LD_LIBRARY_PATH, o primeiro diretório vence.
function M.fold_private(staged, priv)
	if not priv or #priv.order == 0 then return {} end
	local dirs = {}
	for _, pkg in ipairs(priv.order) do
		local rel = "/usr/lib/lpm/" .. pkg
		local dst = staged .. rel
		util.makedirs(dst)
		-- cp do CONTEÚDO do staging do provedor (o payload já ignora os
		-- scripts/metadados do doador — mesma regra de sempre)
		util.sh("cp -a " .. esc(priv.dirs[pkg]) .. "/. " .. esc(dst) .. "/")
		dirs[#dirs + 1] = rel
	end
	return dirs
end

--- troca cada ELF de <staged>/usr/bin por um wrapper gerado; o binário
-- real vai para /usr/libexec/lpm/<app>/<nome>. Scripts (não-ELF) ficam
-- como estão. retorna lista de bins embrulhados | nil, msg
function M.wrap_bins(staged, app_name, priv_dirs)
	local bin_dir = staged .. "/usr/bin"
	if not util.dir_exists(bin_dir) then return {} end
	local out, code = util.capture(
		"find " .. esc(bin_dir) .. " -maxdepth 1 -type f -print 2>/dev/null")
	if not out or out == "" then return {} end
	local lp = table.concat(priv_dirs, ":")
	local wraps = {}
	for path in out:gmatch("[^\r\n]+") do
		local f = io.open(path, "rb")
		local magic = f and (f:read(4) or "")
		if f then f:close() end
		if magic == "\127ELF" then -- 0x7F 45 4C 46 (fmt decimal: style do lpm)
			local base = path:match("([^/]+)$")
			local real_dir = staged .. "/usr/libexec/lpm/" .. app_name
			util.makedirs(real_dir)
			local real = real_dir .. "/" .. base
			if not os.rename(path, real) then
				return nil, ("could not move %s into %s inside the payload"):format(
					base, "/usr/libexec/lpm/" .. app_name)
			end
			local fh = io.open(path, "w")
			if not fh then
				return nil, "could not write the generated wrapper for " .. base
			end
			fh:write("#!/bin/sh\n" ..
				"# generated by lpm: this package carries private donor libs\n" ..
				"# and resolves them ONLY inside this process — the system\n" ..
				"# libs are never touched.\n" ..
				'export LD_LIBRARY_PATH="' .. lp .. '${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' ..
				'exec "' .. "/usr/libexec/lpm/" .. app_name .. "/" .. base .. '" "$@"\n')
			fh:close()
			util.sh("chmod 755 " .. esc(path))
			wraps[#wraps + 1] = "/usr/bin/" .. base
		end
	end
	return wraps
end

--- roda xbps-create (cwd no repósito, destdir=staging) e xbps-rindex -a.
-- tudo roda como usuário no ~/.cache; NÃO toca no sistema. retorna
-- { xbps_path = ... } | nil, msg
-- scan (opcional): resultado de elf.scan(staged); com ele o .xbps recebe
-- --shlib-requires com os sonames REAIS que o payload exige (menos os que
-- o próprio payload provê), e o xbps resolve a descrição igual ao dos
-- pacotes oficiais.
function M.execute(entry, cfg, profile, staged, scan, tx, host_shlibs)
	local ok_tool, err_tool = M._check_create_tool()
	if not ok_tool then return nil, err_tool end

	-- bolha privada (v1.2): os sonames e os pacotes que a bolha resolve
	-- NÃO podem virar dep/shreq — o soname privado não está no sistema e
	-- a checagem global de shlibs do xbps travaria a transação toda.
	local txp = tx and tx.private or nil

	local repo_dir = util.expand_path(cfg.install_repo_dir or profile.install_repo_dir)
	util.makedirs(repo_dir)

	local pkgver = M.host_pkgver(entry)
	-- host_shlibs (v1.2.1): mapa { soname = pkg } para o aliasing
	-- automático — traduz deps estilo 'libc6' para o nome real do host
	-- v2.0: a tradução de nomes AGORA RECEBE O PLANO — tx.solved (provas
	-- da cadeia sobre pkgdb/repodata) e tx.repo_shlibs (repodata). Sem
	-- os campos, comportamento idêntico ao da 1.2.1 (compatível).
	local deps = M.host_deps(entry, profile.pm or "xbps", host_shlibs,
		tx and tx.solved, tx and tx.repo_shlibs)
	for i, d in ipairs(deps) do deps[i] = M.rewrite_dep(d, tx, entry.name) end
	-- rewrite pode unificar deps (perl-base e perlapi→perl-base): dedupe,
	-- e DROPA os pacotes resolvidos na bolha privada (seu payload entra
	-- dentro do .xbps deste pacote, não como dep do sistema)
	local seen_d = {}
	local unique = {}
	for _, d in ipairs(deps) do
		local nm = d:match("^([^%[<>=~%s]+)") or d
		nm = nm:match("^(.-):%w+$") or nm
		if txp and txp.pkgs and txp.pkgs[nm] then
			-- resolvido na bolha — pula a dep
		elseif not seen_d[d] then
			seen_d[d] = true
			unique[#unique + 1] = d
		end
	end
	deps = unique

	-- descrição do binário: sonames que o payload exige (truth ganha sobre
	-- as soname-deps DECLARADAS pelo doador); os servidos pela bolha
	-- privada saem (o payload dele está em /usr/lib/lpm dentro do pacote)
	local shreq = {}
	if scan then
		local seen = {}
		for _, s in ipairs(scan.needed_names or {}) do
			if not seen[s] and not (scan.self and scan.self[s])
				and not (txp and txp.sonames and txp.sonames[s])
				and not (tx and tx.orphans and tx.orphans[s]) then
				seen[s] = true
				shreq[#shreq + 1] = s
			end
		end
	end

	local flags = {}
	flags[#flags + 1] = "-n " .. esc(pkgver)
	flags[#flags + 1] = "-s " .. esc(entry.desc ~= "" and entry.desc or entry.name)
	if entry.arch then flags[#flags + 1] = "-A " .. esc(M.pool_arch(entry)) end
	if entry.license and #entry.license > 0 then
		flags[#flags + 1] = "-l " .. esc(table.concat(entry.license, " "))
	end
	if entry.url then flags[#flags + 1] = "-H " .. esc(entry.url) end
	-- xbps-create aceita LISTAS separadas por ESPAÇOS num único arg
	-- ('-D foo>=1.0_1 bar<2.1'); vírgula vira uma dep literal 'a,b' (e o
	-- solver não acha provedor) — validado no host real com props.plist
	if #deps > 0 then flags[#flags + 1] = "-D " .. esc(table.concat(deps, " ")) end
	-- provides virtuais do doador (fora de sonames — os DT_SONAME o rindex
	-- descobre sozinho dos ELF do payload). Formato: 'nome-<versão_xbps>';
	-- nome pode TER '-', o xbps separa no ÚLTIMO '-' (experimento real:
	-- perl base provê 'perlapi-5.40.0-1.0_1' e a dep 'perlapi-5.40.0>=0' casa)
	local provs = {}
	for _, raw in ipairs(entry.provides or {}) do
		local pn = version.parse_dep(raw)
		if pn and pn.name then
			local eff = pn.name:match("^(.-):%w+$") or pn.name
			if not eff:match("%.so") and eff ~= entry.name and not provs[eff] then
				provs[eff] = eff .. "-" .. M.version_to_xbps(entry.version)
			end
		end
	end
	local prov_list = {}
	for _, pv in pairs(provs) do prov_list[#prov_list + 1] = pv end
	if #prov_list > 0 then
		table.sort(prov_list)
		flags[#flags + 1] = "-P " .. esc(table.concat(prov_list, " "))
	end
	-- idem shlib-requires: UM flag com a lista espaçada
	if #shreq > 0 then
		flags[#flags + 1] = "--shlib-requires " .. esc(table.concat(shreq, " "))
	end
	-- v2.0.1: xbps-create NÃO infere DT_SONAME sozinho (emprírico: pool
	-- inteiro sem shlib-provides e o solver global do xbps 0.60 aborta
	-- 'unresolvable shlib' mesmo com a dep exata do provedor presente).
	-- Declaramos EXPLICITAMENTE os sonames que o payload provê (formato
	-- do repodata oficial do Void: soname nú, sem versão), MENOS os
	-- resolvidos na bolha privada (o payload em /usr/lib/lpm não é
	-- shlib-provide público)
	local shprovs = {}
	if scan then
		for son in pairs(scan.self or {}) do
			if not (txp and txp.sonames and txp.sonames[son]) then
				shprovs[#shprovs + 1] = son
			end
		end
	end
	if #shprovs > 0 then
		table.sort(shprovs)
		flags[#flags + 1] = "--shlib-provides " .. esc(table.concat(shprovs, " "))
	end

	-- xbps-create grava o .xbps no CWD; os flags vão no começo e o destdir
	-- POR ÚLTIMO (positional). cwd repósito → .xbps já nasce ao lado do INDEX.
	local out, code = util.capture(
		"cd " .. esc(repo_dir) .. " && xbps-create " ..
		table.concat(flags, " ") .. " " .. esc(staged) .. " 2>&1")
	if code ~= 0 then
		return nil, "xbps-create failed:\n" .. util.trim(out)
	end

	local xbps_path = repo_dir .. "/" .. pkgver .. "." .. M.pool_arch(entry) .. ".xbps"
	if not util.file_exists(xbps_path) then
		return nil, "xbps-create exited 0 but did not create " .. xbps_path
	end
	-- legado pré-v2.0: o mesmo pkgver pode ter nascido como .any.xbps e o
	-- rindex o recusava → lixo no pool; remove na reconversão
	local legacy_any = repo_dir .. "/" .. pkgver .. ".any.xbps"
	if legacy_any ~= xbps_path and util.file_exists(legacy_any) then
		util.sh("rm -f " .. esc(legacy_any))
	end

	local rix, rixc = util.capture(
		"xbps-rindex -f -a " .. esc(xbps_path) .. " 2>&1")
	if rixc ~= 0 then
		return nil, "xbps-rindex -a failed:\n" .. util.trim(rix)
	end
	-- v2.0: o rindex RECUSA .xbps e AINDA sai com código 0 ("index:
	-- ignoring …, unmatched arch (any)" foi reproduzido ao vivo) — exit
	-- code sozinho mente; 'ignoring' na saída é falha, não aviso.
	if rix:find("ignoring", 1, true) then
		return nil, "xbps-rindex refused to index the conversion:\n" .. util.trim(rix)
	end
	-- repo é só de .xbps: o staging era precário durante a conversão, fica
	-- pra trás apenas como lixo — limpa (subprocesso: nada de FFI)
	util.sh("rm -rf " .. esc(staged))
	-- prune de versões velhas do MESMO nome+arch: reconverter empilhava
	-- .xbps no repo (m4-1.4.21_2 + m4-1.4.21.2_1 coexistiam) e o solver
	-- guardaria duas candidatas para o nome. Só o recém-criado fica.
	local old = M.stale_versions(repo_dir, entry.name, M.pool_arch(entry), pkgver)
	for _, oldi in ipairs(old) do
		util.sh("rm -f " .. esc(oldi.path))
		util.capture("xbps-rindex -r " .. esc(repo_dir) .. " " ..
			esc(oldi.pkgver) .. " 2>&1")
		print("pruned: " .. oldi.pkgver .. " (superseded by " .. pkgver .. ")")
	end
	return { xbps_path = xbps_path, pkgver = pkgver, deps_str = deps, shreq = shreq }
end

--- dry-run da transação de instalação pelo SOLVER DO HOST (sem root).
-- `xbps-install -n -R <repodir> <pkgver...>`: a própria ferramenta nativa
-- decide se cabe, conflitos, etc. v0.3: aceita UM pkgver (string) ou uma
-- LISTA (transação multi-pacote da cadeia). retorna { line=... } | nil,msg
function M.dry_install(pkgvers, repodir)
	if not util.which("xbps-install") then
		return nil, "xbps-install is not in PATH"
	end
	if type(pkgvers) == "string" then pkgvers = { pkgvers } end
	local flags = { esc(repodir) }
	for _, pv in ipairs(pkgvers) do flags[#flags + 1] = esc(pv) end
	local out, code = util.capture(
		"xbps-install -n -R " .. table.concat(flags, " ") .. " 2>&1")
	if code ~= 0 then
		return nil, util.trim(out)
	end
	return { line = util.trim(out) }
end

--- comando FINAL (com sudo) que o usuário roda para concluir.
-- v0.3: aceita um pkgver (string) ou lista (cadeia multi-pacote).
function M.final_command(pkgvers, repodir)
	if type(pkgvers) == "string" then pkgvers = { pkgvers } end
	local flags = { esc(util.expand_path(repodir)) }
	for _, pv in ipairs(pkgvers) do flags[#flags + 1] = esc(pv) end
	return "sudo xbps-install -R " .. table.concat(flags, " ")
end

return M
