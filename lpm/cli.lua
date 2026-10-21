-- lpm/cli.lua -- comandos do lpm.
-- NOTA DE LÍNGUA: strings que chegam ao usuário são EM INGLÊS (1.0); os
-- comentários continuam em pt-BR (voz de dev do projeto).

local script_path = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local root = script_path:match("^(.*)/lpm/cli%.lua$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local util = require("lpm.util")
local detect = require("lpm.detect")
local fetch = require("lpm.fetch")
local preflight = require("lpm.preflight")
local convert = require("lpm.convert")
local chain = require("lpm.chain")
local elf = require("lpm.elf")
local version = require("lpm.version")
local config = require("lpm.config")

local M = {}

local sess -- cache da ficha do host/perfil (uma vez por execução)
local function session()
	if sess then return sess end
	local d = detect.detect()
	if not d.profile then
		io.stderr:write("lpm: " .. (d.reason or "unsupported host") .. "\n")
		os.exit(1)
	end
	local profile = dofile(root .. "/profiles/" .. d.profile .. ".lua")
	local config = require("lpm.config").load(profile)
	sess = { detected = d, profile = profile, cfg = config }
	return sess
end

local function pm_adapt() -- adaptador do PM nativo do host
	local s = session()
	return require("lpm.pm." .. s.detected.pm)
end

-- escape para shell (nomes de arquivo do donor que sempre trajam aspas)
local function esc(s)
	return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local indices = {}
--- doador efetivo deste comando (flag --donor=<id>, default arch).
-- doadores alternativos vivem em profile.donors (arch é profile.donor).
-- v1.1: reencadeia o espelho do doador com config.apply_mirror — a
-- precedência é flag > config.mirrors[do id do doador] > perfil. A troca
-- NUNCA muta o perfil (apply_mirror devolve cópia). erro de config sai
-- com exit 2 (uso errado do usuário, não crash).
local function donor_of(args)
	local s = session()
	local d
	if not args.donor then
		d = s.profile.donor
	else
		d = (s.profile.donors or {})[args.donor] or
			(args.donor == s.profile.donor.id and s.profile.donor or nil)
		if not d then
			local ks = {}
			for k in pairs(s.profile.donors or {}) do ks[#ks + 1] = k end
			table.sort(ks)
			io.stderr:write("lpm: unknown donor '" .. args.donor ..
				"' (available: " .. table.concat(ks, ", ") .. ")\n")
			os.exit(2)
		end
	end
	local base = args.mirror or (s.cfg.mirrors or {})[d.id]
	local nd, merr = config.apply_mirror(d, base)
	if not nd then
		io.stderr:write("lpm: " .. tostring(merr) .. "\n")
		os.exit(2)
	end
	if nd.mirror ~= d.mirror then
		-- aviso sempre que a base difere do default do perfil (stderr não
		-- suja saída consumível por script)
		io.stderr:write(("lpm: mirror override for '%s': %s (profile default: %s)\n"):format(
			d.id, nd.mirror, d.mirror))
	end
	-- v2.0.1 honestidade: os índices .db são cacheados por (mtime:size) e
	-- NÃO sabem de qual base vieram. Override sem re-sync = o solver
	-- consulta a ERA ERRADA (experiência real: bitwarden com mirror do
	-- Archive e o electron baixado ainda do .db atual — glibc 2.44 numa
	-- era 2.41). Cada era é auto-consistente (índice+pkgs do MESMO
	-- snapshot); o desalinhado é avisado pela proveniência do cache.
	local dbprov = util.join(util.expand_path(nd.db_dir or s.cfg.db_dir), ".mirror_base")
	local have_base = util.file_exists(dbprov) and util.trim(util.read_file(dbprov))
	if have_base and have_base ~= nd.mirror then
		io.stderr:write(("lpm: NOTE: donor indices in the cache are from '%s'; this switch did NOT re-fetch them\n"):format(have_base))
		io.stderr:write("lpm: re-index from this base once: lpm sync --force --mirror=" ..
			nd.mirror .. "\n")
	end
	return nd
end

local function load_indices(force, donor)
	local s = session()
	local a = donor or s.profile.donor
	-- db_dir é PROPRIEDADE DO DOADOR (cada doador tem cache próprio);
	-- config.lua não tranca isso num só path
	local db_dir = util.expand_path(a.db_dir or s.cfg.db_dir)
	util.makedirs(db_dir)
	local donormod = require("lpm.repos." .. (a.module or a.id))

	for _, repo in ipairs(a.repos) do
		local dbpath = util.join(db_dir, repo.id .. ".db")
		local cachef = db_dir .. "/" .. repo.id .. ".idx.lua"
		local key = a.id .. "/" .. repo.id

		-- v2.0 — CAMINHO QUENTE: o índice parseado vem do dump Lua, chaveado
		-- pela assinatura (mtime:size) do .db. .db igual = ZERO tar/xz/zstd,
		-- ZERO parse de 15k desc: o comando inteiro cai de ~10s para <1s.
		if not force then
			local sig = util.file_sig(dbpath)
			if sig then
				local cached = util.load(cachef)
				-- formato flat (v2.0): uma CÓPIA dos entries; by_name/
				-- by_provides são ÍNDICES de posição e voltam a apontar
				-- pros mesmos objetos no reload (o grafo de refs é refeito)
				if cached and cached.sig == sig and cached.flat and cached.flat.list then
					local list, by_name, by_provides =
						cached.flat.list, {}, {}
					for n, i in pairs(cached.flat.names or {}) do
						if list[i] then by_name[n] = list[i] end
					end
					for n, i in pairs(cached.flat.provides or {}) do
						if list[i] then by_provides[n] = list[i] end
					end
					for _, e in ipairs(list) do e.repo = repo.id end
					indices[key] = { by_name = by_name, by_provides = by_provides, list = list }
					goto next_repo
				end
			end
			-- sem sig (nunca baixado) ou cache velho: segue o caminho lento
		end

		if force or not util.file_exists(dbpath) then
			print("sync: downloading " .. repo.id .. " …")
			local ok, err = fetch.download(repo.url, dbpath)
			if not ok then
				io.stderr:write("lpm: " .. err .. "\n" ..
					"  hint: index downloads happen on demand; you can also pre-fetch them with `lpm sync`\n")
				os.exit(1)
			end
			-- proveniência da era: a base da qual ESTE .db veio (o cli usa
			-- isso pra avisar troca de mirror sem re-sync — cache sig-only
			-- não sabe de onde veio)
			util.write_file(db_dir .. "/.mirror_base", a.mirror .. "\n")
		end
		local sig = util.file_sig(dbpath)
		local exdir = db_dir .. "/" .. repo.id
		local ok2, err2 = donormod.extract_db(dbpath, exdir)
		if not ok2 then
			io.stderr:write("lpm: " .. err2 .. "\n")
			os.exit(1)
		end
		local idx, err3 = donormod.build_index(exdir)
		if not idx then
			io.stderr:write("lpm: " .. tostring(err3) .. "\n")
			os.exit(1)
		end
		for _, e in ipairs(idx.list) do e.repo = repo.id end
		indices[key] = idx
		if sig then
			-- v2.0: dump FLAT — refs compartilhadas (by_name/by_provides
			-- → list) viram índice de posição; no load o grafo é remontado
			local pos = {}
			for i, e in ipairs(idx.list) do pos[e] = i end
			local names, provides = {}, {}
			for n, e in pairs(idx.by_name) do names[n] = pos[e] end
			for n, e in pairs(idx.by_provides) do provides[n] = pos[e] end
			util.save({ sig = sig, flat = { list = idx.list,
				names = names, provides = provides } }, cachef)
		end
		::next_repo::
	end
	return indices
end

function M.find(name, donor)
	local s = session()
	local d = donor or s.profile.donor
	load_indices(false, d)
	local found = {}
	for _, repo in ipairs(d.repos) do
		local e = indices[d.id .. "/" .. repo.id].by_name[name]
		if e then found[#found + 1] = e end
	end
	return found
end

-- comandos --------------------------------------------------------------

function M.cmd_detect()
	local d = detect.detect()
	print("OS:          " .. (d.os_pretty or d.os_id))
	print("id:          " .. d.os_id)
	print("native PM:   " .. tostring(d.pm))
	print("lpm profile: " .. (d.profile or "none"))
	if d.reason then print("why:         " .. d.reason) end
	return 0
end

function M.cmd_sync(args)
	local d = donor_of(args)
	load_indices(args.force == true, d)
	for _, repo in ipairs(d.repos) do
		local idx = indices[d.id .. "/" .. repo.id]
		print(("%s: %d packages indexed"):format(d.id .. "/" .. repo.id, #idx.list))
	end
	return 0
end

function M.cmd_search(args)
	if not args[1] then
		print("usage: lpm search <term> [--repo core|extra]")
		return 2
	end
	local s = session()
	local d = donor_of(args)
	local term = args[1]:lower()
	load_indices(false, d)
	local n = 0
	for _, repo in ipairs(d.repos) do
		if not args.repo or args.repo == repo.id then
			for _, e in ipairs(indices[d.id .. "/" .. repo.id].list) do
				if e.name:lower():find(term, 1, true) or e.desc:lower():find(term, 1, true) then
					print(("%-26s %-18s %-5s %s"):format(e.name, e.version, e.repo, e.desc))
					n = n + 1
					if n >= 60 then
						print("… (showing the first 60 results; narrow the term)")
						return 0
					end
				end
			end
		end
	end
	if n == 0 then
		print("nothing for '" .. args[1] .. "'")
	end
	return 0
end

function M.cmd_info(args)
	if not args[1] then
		print("usage: lpm info <package> [--repo core|extra]")
		return 2
	end
	local found = M.find(args[1], donor_of(args))
	if args.repo then
		local fl = {}
		for _, e in ipairs(found) do if e.repo == args.repo then table.insert(fl, e) end end
		found = fl
	end
	if #found == 0 then
		print("not found: " .. args[1])
		return 1
	end
	local e = found[1]
	if #found > 1 then
		print(("the name exists in %d repos; using %s (pick with --repo):"):format(
			#found, e.repo))
	end
	print("name:        " .. e.name)
	print("version:     " .. e.version)
	print("repo:        " .. e.repo)
	print("file:        " .. tostring(e.filename))
	print("arch:        " .. tostring(e.arch))
	print("size:        " .. tostring(e.csize))
	print("url:         " .. tostring(e.url))
	print("licenses:    " .. table.concat(e.license or {}, ", "))
	print("description: " .. e.desc)
	if #e.provides > 0 then print("provides:    " .. table.concat(e.provides, ", ")) end
	print("depends (" .. #e.depends .. "):")
	for _, d in ipairs(e.depends) do
		print("  - " .. d.name .. (d.ver and (" " .. d.op .. " " .. d.ver) or ""))
	end
	if #e.conflicts > 0 then print("conflicts:   " .. table.concat(e.conflicts, ", ")) end
	if #e.replaces > 0 then print("replaces:    " .. table.concat(e.replaces, ", ")) end
	return 0
end

-- mapa { soname = pkgname } do host, quando o adaptador do PM o expõe
local function host_shlibs()
	local pm = pm_adapt()
	if pm.shlib_provides then
		local m = pm.shlib_provides()
		if next(m) then return m end
	end
	return nil
end

-- versão da 'glibc' instalada, na língua do host (só o xbps tem comparador
-- próprio portado; outros PMs: nil → preflight degrada a aviso)
local function host_glibc(installed)
	local s = session()
	local canon = preflight.canonical("glibc")
	local name = preflight.across(canon, s.detected.pm)
	return installed[name], name
end

function M.cmd_check(args)
	if not args[1] then
		print("usage: lpm check <package>")
		return 2
	end
	local s = session()
	local d = donor_of(args)
	load_indices(false, d)
	local found = M.find(args[1], d)
	if #found == 0 then
		print("not found: " .. args[1])
		return 1
	end
	local e = found[1]
	local installed = pm_adapt().installed()
	local ok, issues = preflight.check_deps(e, installed, d.style, s.detected.pm,
		host_shlibs(), require("lpm.repos.xbpsrepo").bridge())
	print(("check: %s-%s (repo %s) against the host"):format(e.name, e.version, e.repo))
	print(("  depends: %d declared by the donor"):format(#e.depends))
	if ok then
		print("  ✔ fits the host")
		return 0
	end
	for _, iss in ipairs(issues) do
		print("  × " .. iss)
	end
	print(("  ✘ %d problem(s); nothing will be downloaded/installed"):format(#issues))
	return 1
end

--------------------------------------------------------------------------- -- doctor: diagnóstico das peças que o lpm usa: interpretador
-- Lua, ferramentas externas (todas via subprocesso por design), xbps,
-- permissões de escrita nos caches do lpm e frescor dos índices.
-- Saida esperada: ✓/✗ por item + dica de conserto ("sudo xbps-install -S …").
function M.cmd_doctor(args)
	local s = session()
	local d = donor_of(args)
	local checks = {}

	local function add(ok, label, hint)
		checks[#checks + 1] = {
			ok = ok and true or false,
			label = label,
			hint = not ok and hint or nil,
		}
		return ok
	end

	-- 1. interpretador (a linguagem do lpm usa goto: Lua 5.2+; 5.1 não serve)
	add(not _VERSION:find("Lua 5%.1"),
		"lua interpreter: " .. _VERSION,
		"needs Lua 5.2+ (never 5.1/LuaJIT); on Void: sudo xbps-install -S lua5.4")

	-- 2. ferramentas externas. A dica é o pacote do Void correspondente
	local tools = {
		{ "tar", "tar" }, { "zstd", "zstd" }, { "gzip", "gzip" },
		{ "sha256sum", "coreutils" },
	}
	if d.id == "debian" then
		-- o xz do payload .deb abre via lzma do python3 (binário xz não
		-- é exigido — experimento da prova de conceito Debian)
		tools[#tools + 1] = { "python3", "python3 (payload .deb com xz/lzma)" }
	end
	for _, t in ipairs(tools) do
		if not add(util.which(t[1]) and true or false,
			"tool: " .. t[1],
			"on Void: sudo xbps-install -S " .. t[2])
		then end
	end
	-- downloader (xbps-fetch já vem com o próprio xbps do Void)
	add(util.which("xbps-fetch", "curl", "wget") and true or false,
		"downloader (xbps-fetch/curl/wget)",
		"on Void: sudo xbps-install -S curl")

	-- 3. PM nativo: as quatro ferramentas de transação que o lpm usa
	for _, b in ipairs({ "xbps-install", "xbps-create", "xbps-rindex", "xbps-query" }) do
		add(util.which(b) and true or false, "xbps tool: " .. b,
			"this should never be missing on a Void system")
	end

	-- 4. caches do lpm: writable? (canário em cada diretorio)
	local dirs = {
		{ "conversion repo (install target of the final command)",
			util.expand_path(s.cfg.install_repo_dir or s.profile.install_repo_dir) },
		{ ("donor index cache (%s)"):format(d.id),
			util.expand_path(d.db_dir or s.cfg.db_dir) },
	}
	for _, dd in ipairs(dirs) do
		util.makedirs(dd[2])
		local fp = dd[2] .. "/.lpm_probe"
		local fh = io.open(fp, "w")
		local okw = false
		if fh then fh:write("ok"); fh:close(); os.remove(fp); okw = true end
		add(okw, "writable: " .. dd[2], "check permissions of " .. dd[2])
	end

	-- 5. índices: presentes? quantos dias (mtime)? velho demais = sync --force
	local db_dir = util.expand_path(d.db_dir or s.cfg.db_dir)
	local nidx, maxage = 0, 0
	for _, repo in ipairs(d.repos) do
		local dbpath = util.join(db_dir, repo.id .. ".db")
		if util.file_exists(dbpath) then
			nidx = nidx + 1
			local out = util.capture("stat -c %Y '" .. dbpath .. "' 2>/dev/null")
			local t = tonumber(util.trim(out or "")) or 0
			local days = os.time() - t
			days = math.floor(days / 86400)
			if days > maxage then maxage = days end
		end
	end
	if nidx == 0 then
		add(false, "donor indices: none yet (" .. d.id .. ")",
			"run: lpm sync")
	else
		add(maxage <= 21, ("donor indices: %d/%d present, oldest %d day(s)"):format(
			nidx, #d.repos, maxage),
			maxage > 21 and "run: lpm sync --force" or nil)
	end

	-- 5b. ponte com o repodata do host (v2.0): o aliasing NÃO depende dela
	-- (degrada para o mapa instalado), mas com ela o plano fica menor e
	-- nomes renomeados entre distros ('gtk3' → 'gtk+3') resolvem sós.
	local bridge = require("lpm.repos.xbpsrepo").bridge()
	local bcount = 0
	if bridge then
		for _ in pairs(bridge.shlibs) do bcount = bcount + 1 end
	end
	add(bridge ~= nil,
		("host repodata bridge: %d sonames readable"):format(bcount),
		"xbps refreshes its copy on every repo sync — run once: sudo xbps-install -S")

	-- 6. alvo de conversão: o par suportado é x86_64 (host Reliably)
	local out = util.capture("uname -m 2>/dev/null")
	local mach = util.trim(out or "?")
	add(mach == "x86_64", "host machine: " .. mach,
		"lpm only converts x86_64 (host↔donor same-arch); other arches are untested")

	-- veredicto
	local bad = 0
	print("lpm doctor — what this machine needs to run lpm:")
	for _, c in ipairs(checks) do
		if not c.ok then bad = bad + 1 end
		print(("  %s %s"):format(c.ok and "✔" or "✘", c.label))
		if c.hint then print("      " .. c.hint) end
	end
	if bad == 0 then
		print("looks good — `lpm sync && lpm search <term>` is next.")
		return 0
	end
	print(("%d item(s) need attention; lpm aborts before touching anything."):format(bad))
	return 1
end

-- ciclo de vida (limpeza) --------------------------------------------------

--- limpa os caches do lpm. Padrão: o repositório local de conversões (os
-- .xbps que ELE construiu — o host mantém o que já está instalado).
-- --all: também os índices dos doadores (sync baixa de novo). paths são SEMPRE
-- sub-diretórios de ~/.cache/lpm (ou dir configurado) com sanidade de escopo.
local function cache_dir_ok(p)
	if not p or p == "" or p:sub(1, 1) ~= "/" then return false end
	if p:find("%.%.") then return false end -- sem '..'
	if p == "/" or #p < 10 then return false end
	return true
end

function M.cmd_clean(args)
	local s = session()
	local repo_dir = util.expand_path(s.cfg.install_repo_dir or s.profile.install_repo_dir)
	if not cache_dir_ok(repo_dir) then
		io.stderr:write("lpm: refusing to wipe suspicious path '" .. tostring(repo_dir) .. "'\n")
		return 1
	end
	local out = util.capture("ls -1 '" .. repo_dir .. "' 2>/dev/null | grep -c '\\.xbps$'")
	local n = tonumber(util.trim(out or "0")) or 0
	print("cleaning conversion repo " .. repo_dir .. " (" .. n .. " .xbps; anything already installed on the host stays)")
	util.sh("rm -rf -- " .. "'" .. repo_dir:gsub("'", [['"'"']]) .. "'")
	util.makedirs(repo_dir)
	if args.all then
		local donors = { s.profile.donor }
		for _, dd in pairs(s.profile.donors or {}) do donors[#donors + 1] = dd end
		for _, dd in ipairs(donors) do
			local db_dir = util.expand_path(dd.db_dir or s.cfg.db_dir)
			if cache_dir_ok(db_dir) then
				print("cleaning donor index cache " .. db_dir)
				util.sh("rm -rf -- " .. "'" .. db_dir:gsub("'", [['"'"']]) .. "'")
			end
		end
		print("indices will be re-downloaded on the next `lpm sync`/`search`/`install`.")
	end
	return 0
end

function M.cmd_install(args)
	local nomes = {}
	local i = 1
	while args[i] do nomes[#nomes + 1] = args[i]; i = i + 1 end
	if #nomes == 0 then
		print("usage: lpm install <package> [package...] [--repo core|extra]")
		return 2
	end
	local s = session()
	local d = donor_of(args)
	-- v2.0.3: órfãos declarados pelo usuário (--orphan=SONAME[,SONAME...]).
	-- Explícito, nunca automático: o lpm prefere bloquear a esconder.
	local orphans = {}
	if type(args.orphan) == "string" then
		for so in args.orphan:gmatch("[^,]+") do
			orphans[so] = true
			io.stderr:write(("lpm: NOTE: --orphan=%s — a soname with NO provider anywhere will be overlooked in this run; dlopen-only consumers skip it at runtime\n"):format(so))
		end
	end
	load_indices(false, d)
	local idxs = {}
	for _, repo in ipairs(d.repos) do
		idxs[#idxs + 1] = indices[d.id .. "/" .. repo.id]
	end
	local function donor_search(name, via_provides)
		for _, idx in ipairs(idxs) do
			local e = via_provides and idx.by_provides[name] or idx.by_name[name]
			if e then return e end
		end
		return nil
	end

	local founds = {}
	for _, n in ipairs(nomes) do
		local found = M.find(n, d)
		if args.repo then
			local fl = {}
			for _, e in ipairs(found) do if e.repo == args.repo then table.insert(fl, e) end end
			found = fl
		end
		if #found == 0 then
			io.stderr:write("lpm: not found: " .. n .. "\n")
			return 1
		elseif #found > 1 then
			local acc = {}
			for _, f in ipairs(found) do acc[#acc + 1] = f.repo end
			io.stderr:write("lpm: '" .. n .. "' exists in " ..
				table.concat(acc, ", ") .. "; disambiguate with --repo\n")
			return 1
		end
		founds[#founds + 1] = found[1]
	end

	local installed = pm_adapt().installed()
	local shlibs = host_shlibs()
	local provides = (pm_adapt().provides or function() return nil end)()
	-- v2.0 — PONTE com o repodata do host: satisfação e tradução de nomes
	-- automáticas ('gtk3' do doador → 'gtk+3' do Void) mesmo quando o
	-- componente não está instalado aqui (o solver puxa do repo nativo).
	-- nil → degrada para o comportamento 1.2.1 (mapa instalado).
	local bridge = require("lpm.repos.xbpsrepo").bridge()
	local ctx = {
		search = donor_search,
		installed = installed,
		shlibs = shlibs,
		host_provides = provides,
		repo_shlibs = bridge and bridge.shlibs or nil,
		repo_provides = bridge and bridge.provides or nil,
		donor_style = d.style,
		host_style = s.detected.pm,
		-- v1.2: conflito de soname com provedor que sombreia nativo vira
		-- bolha privada (payload dentro do pacote do app) em vez de abortar
		allow_private = true,
	}
	local plan = chain.plan(founds, ctx)
	if not plan.ok then
		print(("the dependency chain has %d problem(s); nothing was downloaded:"):format(#plan.issues))
		for _, iss in ipairs(plan.issues) do io.stderr:write("× " .. iss .. "\n") end
		io.stderr:write("lpm: chain aborted before any download\n")
		return 1
	end
	local solved = {}
	for dep, hp in pairs(plan.solved or {}) do solved[#solved + 1] = dep .. " → " .. hp end
	if #solved > 0 then
		table.sort(solved)
		print(("auto-aliasing: %d dep(s) ride host components by soname bridge: %s"):format(
			#solved, table.concat(solved, ", ")))
	end
	if #plan.ordered > #founds then
		print(("chain: %d package(s) to convert (%d requested on the CLI):"):format(
			#plan.ordered, #founds))
		for _, e in ipairs(plan.ordered) do
			print(("  + %s-%s ← %s"):format(e.name, e.version, plan.why[e.name] or "?"))
		end
	end
	local pnames = {}
	for k in pairs(plan.private_nodes) do pnames[#pnames + 1] = k end
	table.sort(pnames)
	if #pnames > 0 then
		print(("chain: %d donor lib(s) folded as PRIVATE (they would shadow host packages; they live only inside the app's package):"):format(#pnames))
		for _, k in ipairs(pnames) do
			local pe = plan.private_nodes[k]
			print(("  ~ %s-%s ← %s"):format(pe.name, pe.version,
				plan.private_why[k] or "?"))
		end
	end

	local repo_dir = util.expand_path(s.cfg.install_repo_dir or s.profile.install_repo_dir)
	util.makedirs(repo_dir)
	local glibc_ver = host_glibc(installed)

	-- fase 1: fila de nós — índice do doador resolve nomes/provides ANTES do
	-- download, mas o payload depois revela SODEPS que o índice não declara
	-- (ex.: util-linux-libs precisa de libsystemd.so.0 sem dep no desc).
	-- Soname faltante no mapa → procurar quem PROVIDEs no doador e enfileirar
	-- o provedor (com a própria cadeia dele) até a fila estabilizar.
	-- v1.2: nós com mode="private" NÃO viram .xbps — o payload deles é
	-- foldado dentro do pacote do app (bolha privada; ver convert.lua).
	local fila = {}
	local estado = {}
	local priv = { resolved = {}, dirs = {}, order = {}, state = {}, reg = {} }
	-- mapa de sonames da transação — declarado AQUI (antes de `privado`)
	-- porque a bolha privada escreve nele; Lua local só é visível ao código
	-- DEPOIS da declaração, e o fold roda antes do laço principal
	local nos, tx_shlibs = {}, {}
	for soname, pkg in pairs(shlibs or {}) do tx_shlibs[soname] = pkg end
	for _, e in ipairs(plan.ordered) do
		estado[e.name] = true
		fila[#fila + 1] = { entry = e, why = plan.why[e.name] or "requested on the CLI" }
	end
	for _, k in ipairs(pnames) do
		local pe = plan.private_nodes[k]
		if not priv.state[k] then
			priv.state[k] = true
			fila[#fila + 1] = { entry = pe, why = plan.private_why[k] or "private (would shadow the host)", mode = "private" }
		end
	end
	local function soname_sombra(soname)
		-- DT_NEEDED 'libsystemd.so.0' → chave de provides 'libsystemd.so'
		local base = soname:match("^(.-%.so)%.[%d%.]+$") or soname
		if os.getenv("LPM_DEBUG") then
			io.stderr:write("[debug] shadow: soname=" .. soname .. " base=" .. base ..
				" idxs=" .. #idxs)
			for _, idx in ipairs(idxs) do
				io.stderr:write(" ; " .. (idx.id or "?") .. " biz=" ..
					tostring(idx.by_provides and idx.by_provides[base]))
			end
			io.stderr:write("\n")
		end
		return donor_search(soname, true) or donor_search(base, true)
	end

	-- bolha privada: download + staging + scan de um provedor que sombrearia
	-- o sistema. O payload dele NUNCA vira .xbps; os sonames entram no mapa
	-- da transação como "(private)", e as necessidades RECURSIVAS dele são
	-- resolvidas DENTRO da bolha também (nada vaza pro sistema).
	-- O runtime (glibc/musl/linux) NUNCA é bolha: sombrear o próprio loader
	-- do host quebraria tudo que depende dele.
	local function privado(e, why)
		if priv.reg[e.name] then return true end
		-- o runtime glibc/musl NUNCA é bolha: doubteria o próprio loader
		if e.name == "glibc" or e.name == "musl" or e.name:match("^glibc[%-%.]")
			or e.name:match("^linux$") or e.name:match("^linux%-") then
			io.stderr:write(("× refusing to fold '%s' privately — the system runtime cannot be shadowed even privately; transaction aborted\n"):format(e.name))
			return nil
		end
		print(("private fold: %s-%s downloading %s …"):format(e.name, e.version, e.filename))
		local pkg, err = convert.acquire(e, s.profile, s.cfg, d)
		if not pkg then
			io.stderr:write("lpm: " .. tostring(err) .. "\n")
			return nil, err
		end
		local pstage = repo_dir .. "/" .. convert.host_pkgver(e) .. ".private.staging"
		local ok2, err2 = convert.stage(pkg, pstage, d)
		if not ok2 then
			io.stderr:write("lpm: " .. tostring(err2) .. "\n")
			return nil, err2
		end
		local scan = elf.scan(pstage)
		-- regra central vale TAMBM na bolha: payload mais novo que a glibc
		-- do host não rodaria nem amarrado em LD_LIBRARY_PATH próprio
		if scan.glibc_min and glibc_ver
			and version.xbps_cmp(scan.glibc_min, glibc_ver) > 0 then
			io.stderr:write(("× ABI in the private fold: %s requires glibc %s, the host has %s — refusing (donor newer than the host)\n"):format(
				e.name, scan.glibc_min, glibc_ver))
			return nil
		end
		priv.dirs[e.name] = pstage
		priv.reg[e.name] = true
		priv.order[#priv.order + 1] = e.name
		for son in pairs(scan.self or {}) do
			tx_shlibs[son] = "(*private " .. e.name .. ")"
			if not priv.resolved[son] then priv.resolved[son] = e.name end
		end
		local sons = {}
		for son in pairs(scan.self or {}) do sons[#sons + 1] = son end
		table.sort(sons)
		print(("private fold: %s-%s payload: %d ELF (%s)%s"):format(e.name, e.version,
			scan.elf,
			#sons > 0 and ("provides " .. table.concat(sons, " ")) or "no sonames",
			scan.glibc_min and (" glibc " .. scan.glibc_min) or ""))
		-- necessidades do payload privado: resolvem host → bolha → trave
		for _, soname in ipairs(scan.needed_names) do
			local have = preflight.map_satisfies(tx_shlibs, soname)
			if not have then
				local prov = soname_sombra(soname)
				if not prov then
					io.stderr:write(("× private fold of %s: no donor provider for '%s' — cannot close the private bubble\n"):format(e.name, soname))
					return nil
				end
				local planP = chain.plan({ prov }, ctx, { root_private = true })
				if planP.ok then
					for _, k in ipairs((function() local a = {}; for kn in pairs(planP.private_nodes) do a[#a + 1] = kn end table.sort(a) return a end)()) do
						local pe = planP.private_nodes[k]
						if not priv.state[pe.name] then
							priv.state[pe.name] = true
							fila[#fila + 1] = { entry = pe, mode = "private", why = planP.private_why[pe.name] or
								("provides %s (needed by %s)"):format(soname, e.name) }
						end
					end
					print(("  note: private payload needs '%s' — %s-%s folds too"):format(
						soname, prov.name, prov.version))
				else
					for _, iss in ipairs(planP.issues) do io.stderr:write("× private bubble: " .. iss .. "\n") end
					io.stderr:write("lpm: cannot close the private bubble (fold of " .. e.name .. ")\n")
					return nil
				end
			end
		end
		return true
	end

	local pos = 1

	while pos <= #fila do
		local f = fila[pos]; pos = pos + 1
		if f.mode == "private" then
			if not privado(f.entry, f.why) then
				io.stderr:write("lpm: private fold of " .. f.entry.name .. " failed; nothing was converted\n")
				return 1
			end
			-- private node's own processing slot ends here
		else
		local e = f.entry
		print(("[%s-%s] downloading %s …"):format(e.name, e.version, e.filename))
		local pkg, err = convert.acquire(e, s.profile, s.cfg, d)
		if not pkg then
			io.stderr:write("lpm: " .. tostring(err) .. "\n")
			return 1
		end
		local staged = repo_dir .. "/" .. convert.host_pkgver(e) .. ".staging"
		local ok2, err2 = convert.stage(pkg, staged, d)
		if not ok2 then
			io.stderr:write("lpm: " .. tostring(err2) .. "\n")
			return 1
		end
		local scan = elf.scan(staged)
		f.node = { entry = e, staged = staged, scan = scan, pkgver = convert.host_pkgver(e) }
		nos[#nos + 1] = f.node
		local meu_sonames = {}
		for son in pairs(scan.self or {}) do
			tx_shlibs[son] = "(*payload " .. e.name .. ")"
			meu_sonames[#meu_sonames + 1] = son
		end
		table.sort(meu_sonames)
		print(("[%s-%s] payload: %d ELF, glibc required: %s%s"):format(e.name, e.version,
			scan.elf, scan.glibc_min or "none",
			#meu_sonames > 0 and (" ✔ provides " .. table.concat(meu_sonames, " ")) or ""))
		-- sodeps revelados pelo payload (a barreira delas vem na fase 2)
		for _, soname in ipairs(scan.needed_names) do
			if not preflight.map_satisfies(tx_shlibs, soname) then
				local prov = soname_sombra(soname)
				if os.getenv("LPM_DEBUG") then io.stderr:write(
					("[debug] sodep %s → %s (state=%s)\n"):format(soname,
					prov and (prov.name .. "-" .. prov.version) or "nil",
					prov and tostring(estado[prov.name]) or "-")) end
				if prov and not estado[prov.name] and not priv.state[prov.name] then
					-- guarda da regra central: provedor do doador que bate com
					-- nome instalado no host = substituição de nativo (ver
					-- chain.lua: quebraria quem pede o soname nativo)
					local prov_host = installed[prov.name] or
						installed[preflight.across(preflight.canonical(prov.name), s.detected.pm) or prov.name]
					if prov_host then
						-- v1.2 (ideia do usuário): em vez de abortar, a lib do
						-- doador vira BOLHA PRIVADA dentro do pacote do app —
						-- o sistema nativo fica intocado
						print(("  note: the %s payload needs '%s', and the donor's fix (%s-%s) would shadow the native %s (%s) — folding it as a PRIVATE lib instead"):format(
							e.name, soname, prov.name, prov.version, prov.name, prov_host))
						estado[prov.name] = true -- não tenta tx pelo mesmo nome
						local okp, perr = privado(prov,
							("provides %s, demanded by %s (would shadow %s)"):format(soname, e.name, prov.name))
						if not okp then
							io.stderr:write("lpm: private fold of " .. prov.name .. " failed; nothing was converted\n")
							return 1
						end
					else
						local plan2 = chain.plan({ prov }, ctx)
						if plan2.ok then
							-- v2.0.1: os solves do plan2 (camada A/B) precisam
							-- voltar pro plano MAIN — quem escreve as dep-lines
							-- do .xbps é o tx.solved do plano principal; o solve
							-- do plan2 ficava preso no plano local e a dep saía
							-- nua no .xbps (bug real: 'gdk-pixbuf2'/'libp11-kit'
							-- cru dentro do .xbps do gcr, revelado por
							-- bitwarden com donor de snapshot)
							for dep, hp in pairs(plan2.solved or {}) do
								if plan.solved[dep] == nil then plan.solved[dep] = hp end
							end
							for _, pe in ipairs(plan2.ordered) do
								if not estado[pe.name] then
									estado[pe.name] = true
									fila[#fila + 1] = { entry = pe, why = plan2.why[pe.name] or
										("provides %s (sodep revealed by %s)"):format(soname, e.name) }
								end
							end
							print(("  note: payload needs '%s' and no provider is in the transaction — %s-%s joins the queue"):format(
								soname, prov.name, prov.version))
						else
							for _, iss in ipairs(plan2.issues) do io.stderr:write("× sub-chain: " .. iss .. "\n") end
							io.stderr:write("lpm: cannot close the transaction (origin: " .. e.name .. ")\n")
							return 1
						end
					end
				end
			end
		end
		end -- fecha o else do nó tx
	end

	-- fase 2: barreira por payload, com o mapa da transação
	for _, n in ipairs(nos) do
		local okp, bloqueios, avisos, resolvidos = preflight.check_elf(
			n.entry.name, n.scan, tx_shlibs, glibc_ver,
			bridge and bridge.shlibs or nil, orphans)
		for _, a in ipairs(avisos) do print("  ~ " .. a) end
		if #resolvidos > 0 then
			print(("  [%s] provided sonames: %s"):format(n.entry.name,
				table.concat(resolvidos, ", ")))
		end
		if not okp then
			for _, b in ipairs(bloqueios) do io.stderr:write("× " .. b .. "\n") end
			io.stderr:write("lpm: " .. n.entry.name .. " does not fit this host; transaction aborted\n")
			return 1
		end
	end

	-- fase 3: conversão de todos os nós + UM dry-run com a transação inteira
	-- mapa da transação p/ língua de dep do xbps: pkgvers convertidos e
	-- vpkgs que a transação PROVÊ (deps resolvidas por provide-de-repo
	-- quebram a checagem global de shlibs do xbps 0.60 — rewrite p/ nome
	-- exato 'pkg=pkgver', que o solver casa direto no repo local)
	-- v1.2: bolha privada — cada consumer de soname privado recebe o payload
	-- da bolha EM /usr/lib/lpm/<pkg>/ e os bins ELF dele ganham o wrapper.
	-- acontece ANTES do xbps-create: as libs ficam serem arquivos do pacote.
	local tx = { pkgver = {}, vpkg = {} }
	if next(orphans) then tx.orphans = orphans end
	if #solved > 0 then tx.solved = plan.solved end
	if bridge then tx.repo_shlibs = bridge.shlibs end
	for _, n in ipairs(nos) do
		tx.pkgver[n.entry.name] = convert.version_to_xbps(n.entry.version)
		for _, raw in ipairs(n.entry.provides or {}) do
			local pn = version.parse_dep(raw)
			if pn and pn.name then
				local eff = pn.name:match("^(.-):%w+$") or pn.name
				if not eff:match("%.so") and not tx.vpkg[eff]
					and not tx.pkgver[eff] and eff ~= n.entry.name then
					tx.vpkg[eff] = n.entry.name
				end
			end
		end
	end
	if #priv.order > 0 then
		local pkgs = {}
		for _, p in ipairs(priv.order) do pkgs[p] = true end
		tx.private = { sonames = priv.resolved, pkgs = pkgs }
		for _, n in ipairs(nos) do
			local needs = false
			for _, s in ipairs(n.scan.needed_names or {}) do
				local have = preflight.map_satisfies(tx_shlibs, s)
				if have and have:find("private", 1, true) then
					needs = true
					break
				end
			end
			if needs then
				local dirs = convert.fold_private(n.staged, priv)
				local wraps, werr = convert.wrap_bins(n.staged, n.entry.name, dirs)
				if not wraps then
					io.stderr:write("lpm: " .. tostring(werr) .. "\n")
					return 1
				end
				if #dirs > 0 then
					print(("folding private libs into %s: %s"):format(
						n.entry.name, table.concat(dirs, ", ")))
				end
				if #wraps > 0 then
					print(("wrapped: %s (real binaries under /usr/libexec/lpm/%s)"):format(
						table.concat(wraps, ", "), n.entry.name))
				end
				if #wraps == 0 and #dirs > 0 then
					print("  ~ note: this package has private libs but no ELF in /usr/bin — if it loads them at runtime (python C-extensions etc.), run it with LD_LIBRARY_PATH=" ..
						table.concat(dirs, ":"))
				end
			end
		end
	end

	local pkgvers = {}
	local shadow_warned = false
	for _, n in ipairs(nos) do
		local conv, cerr = convert.execute(n.entry, s.cfg, s.profile, n.staged, n.scan, tx, tx_shlibs)
		if not conv then
			io.stderr:write("lpm: " .. tostring(cerr) .. "\n")
			return 1
		end
		print("converted: " .. conv.xbps_path)
		if #conv.deps_str > 0 then
			print("deps (xbps language): " .. table.concat(conv.deps_str, " "))
		end
		if #conv.shreq > 0 then
			print("shlib-requires: " .. table.concat(conv.shreq, " "))
		end
		pkgvers[#pkgvers + 1] = conv.pkgver
		if not shadow_warned and installed[n.entry.name] then
			shadow_warned = true
			print("notice: '" .. n.entry.name .. "' already exists on the host — the transaction replaces it (update):")
			print("  host has " .. installed[n.entry.name] .. "; the conversion brings " .. conv.pkgver)
		end
	end

	-- lixo da bolha: os stagings privados já foram copiados para dentro
	-- dos pacotes consumers; não precisam sobreviver por si
	for _, p in ipairs(priv.order) do
		util.sh("rm -rf " .. esc(priv.dirs[p]))
	end

	local dry, derr = convert.dry_install(pkgvers, repo_dir)
	if not dry then
		io.stderr:write("lpm: dry-run blocked (nothing was installed):\n" .. tostring(derr) .. "\n")
		return 1
	end
	print("host dry-run (xbps-install -n): " .. dry.line)

	print("\nready — run the final command yourself (it asks for sudo):")
	print("  " .. convert.final_command(pkgvers, repo_dir))
	return 0
end

-- ciclo de vida -------------------------------------------------------------

--- lista o que o lpm já converteu no repo local, com o estado no host.
-- O repo local é o espelho da "prateleira" do lpm: os .xbps de lá são os
-- únicos que `sudo xbps-install -R`, o comando FINAL do install, toca.
function M.cmd_list(args)
	local s = session()
	local repo_dir = util.expand_path(s.cfg.install_repo_dir or s.profile.install_repo_dir)
	if not util.dir_exists(repo_dir) then
		print("conversion repo is empty: " .. repo_dir)
		return 0
	end
	local out = util.capture("ls -1 '" .. repo_dir .. "' 2>/dev/null")
	if out == "" then
		print("conversion repo is empty: " .. repo_dir)
		return 0
	end
	local installed = pm_adapt().installed()
	local linhas = {}
	for pkgver_arch in out:gmatch("[^%s]+") do
		-- nome do arquivo: '<pkgver>.<arch>.xbps' (pkgver = nome-versão,
		-- separador é o ÚLTIMO '-' — nomes podem ter hífen)
		local pkgver, arch = pkgver_arch:match("^(.+)%.(%w[%w_]*)%.xbps$")
		if pkgver then
			local nome = pkgver:match("^(.*)%-(.*)$") or pkgver
			local host_ver = installed[nome]
			local estado
			if host_ver and host_ver == pkgver then
				estado = "installed (came from this repo)"
			elseif host_ver then
				estado = "host has " .. host_ver .. " (not this conversion)"
			else
				estado = "not installed"
			end
			linhas[#linhas + 1] = pkgver .. "  (" .. arch .. ") — " .. estado
		end
	end
	table.sort(linhas)
	print("converted in " .. repo_dir .. ": " .. #linhas)
	for _, l in ipairs(linhas) do
		print("  " .. l)
	end
	return 0
end

function M.cmd_remove(args)
	local nomes = {}
	for i = 1, 10 do
		if args[i] then nomes[#nomes + 1] = args[i] end
	end
	if #nomes == 0 then
		print("usage: lpm remove <package> [package...]")
		return 2
	end
	local installed = pm_adapt().installed()
	local tem = false
	for _, nome in ipairs(nomes) do
		if not installed[nome] then
			io.stderr:write("lpm: '" .. nome .. "' is not installed (nothing to remove)\n")
		else
			tem = true
		end
	end
	if not tem then return 1 end
	-- lpm NUNCA executa o PM nativo; quem decide é sempre o usuário
	print("to remove from the host (asks for sudo):")
	for _, nome in ipairs(nomes) do
		if installed[nome] then
			print("  sudo xbps-remove " .. nome)
		end
	end
	return 0
end

-- entrada ----------------------------------------------------------------

local usage = [[
lpm 2.0 — rent the repositories of famous distros, install via the host's native PM.
usage: lpm <command> [args] [--repo core|extra] [--donor=arch|debian] [--mirror=URL]
                [install: --orphan=SONAME[,SONAME,...]
  detect                what this host is and which lpm profile applies
  doctor                diagnose interpreter, tools and lpm caches
  sync [--force]        download donor indices
  search <term>         search by name/description
  info <package>        donor-side package details
  check <package>       preflight the package against this host
  install <package>     download, check ABI/sonames, convert (.xbps) and print the final sudo command
                        (dependency chains are solved inside the donor; --donor=debian is experimental)
  list                  what lpm converted into its local repo, and how each piece lives in the host
  remove <package>      print the removal sudo command (lpm never runs the PM)
  clean [--all]         wipe lpm caches (default: converted repo only; --all adds donor indices)

v2.0: automatic name bridging against the HOST repo's own repodata (donor
'gtk3' ↔ native 'gtk+3' with no alias table), faster hot paths (parsed
index cache + single-pass host pkgdb), and honest `any`-arch handling.
]]

local function parse_args(argv)
	local args, pos = {}, {}
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a:sub(1, 2) == "--" then
			local k, v = a:match("^%-%-([%w%-]+)=(.*)$")
			if k then
				-- v2.0.3: --orphan= aceita repetição (soma por vírgula)
				if k == "orphan" and args[k] then
					args[k] = args[k] .. "," .. v
				else
					args[k] = v
				end
			else
				k = a:sub(3)
				if k == "repo" and argv[i + 1] and argv[i + 1]:sub(1, 1) ~= "-" then
					i = i + 1
					args.repo = argv[i]
				else
					args[k] = true
				end
			end
		elseif a:sub(1, 1) == "-" then
			local k = a:sub(2)
			if k == "y" then args["yes"] = true
			elseif k == "f" then args["force"] = true
			else args[k] = true end
		else
			pos[#pos + 1] = a
		end
		i = i + 1
	end
	for idx, p in ipairs(pos) do args[idx] = p end
	return args
end

local function main(argv)
	local cmd = table.remove(argv, 1)
	if cmd == nil or cmd == "help" or cmd == "--help" or cmd == "-h" then
		print(usage)
		return 0
	end
	if cmd == "--version" or cmd == "version" then
		print("lpm 2.0.3")
		return 0
	end
	-- guarda de root: o lpm não precisa (e não deve) rodar como root — nunca
	-- instala nada, e root poluiria os caches de $HOME do usuário
	if cmd ~= "--version" and cmd ~= "version" then
		local out = util.capture("id -u 2>/dev/null")
		if util.trim(out or "") == "0" then
			io.stderr:write("lpm: refusing to run as root — lpm never installs anything and the final sudo comes from you at the end.\n")
			os.exit(1)
		end
	end
	cmd = cmd:gsub("%-", "_")
	local f = M["cmd_" .. cmd]
	if not f then
		print("unknown command: " .. cmd .. "\n\n" .. usage)
		return 2
	end
	local args = parse_args(argv)
	return f(args) or 0
end

-- usado como script? executa; required como módulo? devolve main
local nargs = select("#", ...)
local first = nargs > 0 and (...)
local is_module = nargs == 1 and first == "lpm.cli"
if not is_module then
	os.exit(main({ ... }) or 0)
end
return { main = main }
