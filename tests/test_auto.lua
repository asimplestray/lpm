-- tests/test_auto.lua -- v1.2.1: ALIASING AUTOMÁTICO de libs (pedido do
-- usuário: a tabela manual era ineficiente). A verdade vem dos DADOS que
-- já existem — nomes estilo Debian comem pontuação do soname, e cada
-- provedor de virtual declara os sonames dele. Nada de tabela por caso.
--
-- Fixtures FAKE: sem rede, sem pkgdb real.

local here = (arg and arg[0]) or "tests/test_auto.lua"
local root = (here:match("^(.-)/?tests/") or ".")
package.path = root .. "/?.lua;" .. package.path

local chain = require("lpm.chain")
local preflight = require("lpm.preflight")

-- ====== 1. reconstrução: nome estilo Debian → soname ======
local s = preflight.deboname_soname
assert(s("libc6") == "libc.so.6", "libc6")
assert(s("libssl3") == "libssl.so.3", "libssl3")
assert(s("libgcc-s1") == "libgcc-s.so.1", "libgcc-s1")
assert(s("libsqlite3-0") == "libsqlite3.so.0", "libsqlite3-0")
assert(s("libatk-1.0-0") == "libatk-1.0.so.0", "libatk-1.0-0")
assert(s("libstdc++6") == "libstdc++.so.6", "libstdc++6")
assert(s("libffi") == nil, "sem dígitos → fora (é nome de pacote comum)")
assert(s("liblua5.4") == nil, "major embutido no meio não é soname")
assert(s("libisl.so") == nil, "já é soname → não reconstrói")
assert(s("glib2") == nil, "sem prefixo lib → fora")

-- ====== 2. satisfação por reconstrução contra o mapa do host ======
local host = {
	["libc.so.6"] = "glibc", ["libssl.so.3"] = "openssl",
	["libgcc_s.so.1"] = "libgcc", -- CUIDADO: ponto-e-vírgula em vez de hífen
	["libsqlite3.so.0"] = "sqlite", ["libz.so.1"] = "zlib",
}
local d = preflight.deboname_satisfied
assert(d("libc6", host) == "glibc", "libc6 → glibc (ponte libc.so.6)")
assert(d("libssl3", host) == "openssl", "libssl3 → openssl")
assert(d("libgcc-s1", host) == "libgcc", "pontuação comida: '-' × '_'")
assert(d("libsqlite3-0", host) == "sqlite", "sufixo '-0'")
assert(d("libinexistente99", host) == nil, "reconstrução SEM chave no host = nil")
assert(d("libssl3", nil) == nil, "sem mapa de shlibs → nada automático")

-- ====== 3. corroboração: provedor declara sonames, host prova todos ======
local libglvnd = {
	name = "libglvnd", version = "1.7.0-3", repo = "extra",
	provides = {
		{ name = "libgl" }, { name = "libegl" }, { name = "libgles" },
		{ name = "libGL.so", op = "=", ver = "1-7" },
		{ name = "libEGL.so", op = "=", ver = "1-7" },
		{ name = "libGLX.so", op = "=", ver = "0-7" },
	},
	depends = {},
}
local glmap = {
	["libGL.so.1"] = "libglvnd", ["libEGL.so.1"] = "libglvnd",
	["libGLX.so.0"] = "libglvnd",
}
local h = preflight.provider_sonames_on_host(libglvnd, glmap)
assert(h == "libglvnd", "todos os sonames do provedor estão no host: " .. tostring(h))
-- split diferente: host não tem UM deles → não dá pra provar → nil
local glbad = { ["libGL.so.1"] = "libglvnd", ["libEGL.so.1"] = "outro" }
assert(preflight.provider_sonames_on_host(libglvnd, glbad) == nil,
	"corroboração parcial NÃO satisfaz (split de pacotes diferente)")
assert(preflight.provider_sonames_on_host(
	{ name = "x", provides = { { name = "somesh" } } }, glmap) == nil,
	"provedor sem sonames → nada corroborado")
-- e o formato REAL do arch: provides são STRINGS cruas
assert(preflight.provider_sonames_on_host({
	name = "libglvnd",
	provides = { "libegl", "libGL.so=1-7", "libEGL.so=1-7" },
}, glmap) == "libglvnd", "providess em strings cruas do arch corroboram")

-- ====== 4. chain: camada A fecha a dep sem converter nada ======
local E = {
	app = { name = "app", version = "1-1", repo = "extra",
		depends = {
			{ name = "libssl3" },          -- camada A: reconstrói e satisfaz
			{ name = "algo-odd" },         -- sem provider em lugar nenhum
		} },
}
local p = chain.plan({ E.app }, {
	search = function() return nil end,
	installed = {}, shlibs = host,
	donor_style = "deb", host_style = "xbps", allow_private = true,
})
assert(not p.ok, "dep sem provider continua bloqueando (honesto)")
assert(#p.issues == 1, "só a dep sem provider é issue (libssl3 já fechou): "
	.. table.concat(p.issues, " | "))
assert((p.issues[1] or ""):find("algo-odd", 1, true), "issue é da dep certa")

-- ====== 5. chain: camada B — virtual libgl satisfeito pelo host ======
local E2 = {
	game = { name = "game", version = "1-1", repo = "extra",
		depends = { { name = "libgl" } } },
}
local p2 = chain.plan({ E2.game }, {
	search = function(n, via)
		return n == "libgl" and libglvnd or nil
	end,
	installed = {}, shlibs = glmap,
	donor_style = "pacman", host_style = "xbps", allow_private = true,
})
assert(p2.ok, "virtual corroborado por sonames: " .. tostring(p2.issues[1]))
assert(#p2.ordered == 1 and p2.ordered[1].name == "game",
	"provedor NEM entra no plano (trabalho zero, tabela zero)")

-- e com split diferente NEM automático NEM abort falso: enfileira o ít
-- provedor normalmente (o nome dele não existe no host mockado)
local p3 = chain.plan({ E2.game }, {
	search = function(n) return n == "libgl" and libglvnd or nil end,
	installed = { other = "1_1" }, shlibs = glbad,
	donor_style = "pacman", host_style = "xbps", allow_private = true,
})
assert(p3.ok, "sem corroboração cai no fluxo normal: " .. tostring(p3.issues[1]))
assert(#p3.ordered == 2, "provedor entra no plano tx (nada foi assumido)")

-- ====== 6. op de versão: testemunha é ABI; sem testemunha, honesto ======
-- com testemunha (o host provê a ABI do soname), satisfeito mesmo com op
local p4 = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "libssl3", op = ">=", ver = "3.9" };
			{ name = "libc6", op = ">=", ver = "2.34" } } } }, {
		search = function() return nil end,
		installed = {}, shlibs = host,
		donor_style = "deb", host_style = "xbps",
	})
assert(p4.ok, "op-depend com testemunha ABI satisfa: " .. table.concat(p4.issues, " | "))
assert(#p4.ordered == 1, "nada a converter: only app")

-- sem testemunha no mapa: bloqueia honesto (a versão LYING é proibida)
local none = { ["libc.so.6"] = "glibc" } -- sem libssl.so.3
local p5 = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "libssl3", op = ">=", ver = "3.9" } } } }, {
		search = function() return nil end,
		installed = {}, shlibs = none,
		donor_style = "deb", host_style = "xbps",
	})
assert(not p5.ok, "sem testemunha: bloqueia honesto")
assert((p5.issues[1] or ""):find("no provider", 1, true), "motivo honesto")

-- ====== 7. check_deps vê o mesmo que o chain vê (consistência) ======
local okc, issues = preflight.check_deps(
	{ name = "app", depends = { { name = "libssl3" } } },
	{}, "deb", "xbps", host)
assert(okc, "check_deps fecha com autofecha: " .. table.concat(issues, " | "))
okc, issues = preflight.check_deps(
	{ name = "app", depends = { { name = "libssl3" } } },
	{}, "deb", "xbps", nil)
assert(not okc and (issues[1] or ""):find("unresolved", 1, true),
	"sem mapa de shlibs: check_deps segue conservador")

-- ====== 8. tradução no .xbps: host_deps reescreve lidendo o host ======
local convert = require("lpm.convert")
local out = convert.host_deps(
	{ name = "app", depends = { { name = "libc6", op = ">=", ver = "2.34" },
		{ name = "zlib1g" } } }, "xbps", host)
assert(#out == 2, "2 deps de saída: " .. table.concat(out, " "))
assert(out[1]:find("glibc>=", 1, true), "libc6 traduz pro nome do host: " .. out[1])
assert(out[2]:find("zlib", 1, true), "zlib1g: tabela override traduz: " .. out[2])
-- e dep resolvida na BOLHA PRIVADA não vira dep do sistema (pacote que
-- NÃO está na tabela — senão o across traduz antes do automático)
local privmap = {}
privmap["libzub.so.2"] = "(*private libzub)"
local out2 = convert.host_deps(
	{ name = "app", depends = { { name = "libzub2" }, { name = "zlib1g" } } },
	"xbps", privmap)
assert(#out2 == 1 and out2[1]:find("zlib", 1, true),
	"dep da bolha some do .xbps: " .. table.concat(out2, " "))

print("test_auto: OK")
