-- tests/test_version.lua -- os comparadores de versão batem com os originais.
--
-- A metade do pacman vem da suíte oficial vercmptest.sh (casos que-descobre
-- na lista pacman-dev e keyboard do upstream), sem perdição de uma linha:
-- qualquer caso novo só entra aqui LIDO DE FONTE primária, de memória não.

local version = require("lpm.version")

local pacman = function(a, b) return version.pacman_cmp(a, b) end

local function eq(got, want, label)
	if got ~= want then
		error(("falhou: %s → obtive %d, esperava %d"):format(label, got, want), 2)
	end
end

-- iguais --------------------------------------------------------------
eq(pacman("1.0", "1.0"), 0, "1.0 == 1.0")
eq(pacman("1.5-1", "1.5"), 0, "1.5-1 == 1.5 (pkgrel só quando em ambos)")

-- numérico (comportamento do rpmvercmp, a ordem dos casos da suíte do pacman)
eq(pacman("1.0", "1.1"), -1, "1.0 < 1.1")
eq(pacman("1.0.1", "1.0"), 1, "1.0.1 > 1.0")
eq(pacman("51", "49"), 1, "51 > 49")
eq(pacman("49", "51"), -1, "49 < 51")
eq(pacman("1.2.3", "1.2.10"), -1, "1.2.3 < 1.2.10 (numérico, não léxico)")
eq(pacman("1.00", "1.0"), -1, "a MAIS CURTA vence (patch 2011)")
eq(pacman("1a", "1.a"), 1, "1a > 1.a (suíte oficial)")
eq(pacman("23.3.a", "23.3a"), -1, "23.3.a < 23.3a (suíte oficial)")
-- com o patch 2011, conteúdo numérico idêntico deixa de ser empate: a mais
-- curta vence (era a suíte PRÉ-patch que declarava 1.05 == 1.5)
eq(pacman("1.05-1", "1.5-1"), -1, "1.05-1 < 1.5-1 (menor vence pós-patch)")
eq(pacman("1.05b", "1.5b"), -1, "igual ao de cima, com sufixo")
eq(pacman("1.05b", "1.05"), -1, "1.05b < 1.05 (sufixo alpha pré-release)")
-- xbps vs pacman mundo cruzado: _rev não vira rel (sem '-'): a comparação é
-- de versão inteira, sem o atalho do pkgrel
eq(pacman("2.38_1", "2.38"), 1, "2.38_1 > 2.38 (>=2.38 afrouxa; útil pro lpm)")

-- epoch --------------------------------------------------------------
eq(pacman("1:1.0", "1.0"), 1, "epoch vence tudo")
eq(pacman("1:1.0", "1.1"), 1, "epoch > qualquer versão sem epoch")
eq(pacman("1:1.1", "1.1"), 1, "1:1.1 > 1.1")
eq(pacman("0:1.0", "1.0"), 0, "epoch 0 explícito == sem epoch")

-- sufixo alfabético < vazio ('showdown': 1.0a < 1.0) ------------------
eq(pacman("1.0a", "1.0"), -1, "1.0a < 1.0 (pré-release)")
eq(pacman("1.0", "1.0a"), 1, "1.0 > 1.0a")
eq(pacman("1.0rc1", "1.0"), -1, "1.0rc1 < 1.0")

-- tipos mistos --------------------------------------------------------
eq(pacman("a", "1"), -1, "dígito vence alfa")
eq(pacman("2.0", "2.0a"), 1, "2.0 > 2.0a")

-- pkgrel --------------------------------------------------------------
eq(pacman("1.5-1", "1.5-2"), -1, "pkgrel faz diferença quanto ambos")
eq(pacman("1.5-2", "1.5-2"), 0, "pkgrel igual")

-- versões xbps doado cruzado (o caso de uso do lpm na vida real) --------
eq(pacman("2.41", "2.38"), 1, "glibc doado (arch) > pedido via constraint")

-- dpkg ----------------------------------------------------------------
local deb = function(a, b) return version.dpkg_cmp(a, b) end
eq(deb("1.0", "1.1"), -1, "1.0 < 1.1")
eq(deb("1.0~rc1", "1.0"), -1, "~rc1 vem antes (regra do dpkg)")
eq(deb("1.0", "1.0+dfsg"), -1, "'+dfsg' vem depois")
eq(deb("1.0-2", "1.0-1"), 1, "revisão Debian conta")
eq(deb("1:0.5", "0.9"), 1, "epoch dpkg vence")
eq(deb("2.0", "10.0"), -1, "numérico dpkg: 2 < 10")
eq(deb("1.0a", "1.0b"), -1, "alfa dpkg lexicográfico")

-- satisfazer constraints ------------------------------------------------
eq(version.satisfies("pacman", "2.41_1", ">=", "2.38") and 1 or 0, 1, "host 2.41_1 >= 2.38")
eq(version.satisfies("pacman", "2.30_1", ">=", "2.38") and 1 or 0, 0, "host 2.30_1 < 2.38")
eq(version.satisfies("pacman", "2.38", "=", "2.38") and 1 or 0, 1, " Completa restrição igual")
eq(version.satisfies("deb", "1.0~rc1", ">=", "1.0") and 1 or 0, 0, "rc < 1.0 (dpkg)")

-- constraints -----------------------------------------------------------
local d = version.parse_dep("glibc>=2.38")
eq(d.name, "glibc", "parse_dep: name seprado do op")
assert(d.op == ">=" and d.ver == "2.38", " GHC dep com constraints")
local d2 = version.parse_dep("mesa")
assert(d2.name == "mesa" and not d2.op and not d2.ver, "dep sem restrição")
local d3 = version.parse_dep("libfoo-2<3.0")
assert(d3.name == "libfoo-2" and d3.op == "<", "nomes com '-' + '<' no fim")

-- xbps (dewey) — vetores OFICIAIS de tests/libxbps/cmpver/main.c do xbps
local xcasos = {
	{ "foo-1.0", "foo-1.0", 0 },
	{ "foo-1.0", "foo-1.0_1", -1 },
	{ "foo-1.0_1", "foo-1.0", 1 },
	{ "foo-2.0rc2", "foo-2.0rc3", -1 },
	{ "foo-2.0rc3", "foo-2.0rc2", 1 },
	{ "foo-129", "foo-129_1", -1 },
	{ "foo-blah-100dpi-21", "foo-blah-100dpi-21_0", 0 },
	{ "foo-blah-100dpi-21", "foo-blah-100dpi-2.1", 1 },
	{ "foo-1.0.1", "foo-1.0_1", 1 },
}
for i, ca in ipairs(xcasos) do
	local got = version.xbps_cmp(ca[1], ca[2])
	assert(got == ca[3], ("xbps_cmp caso %d: %q vs %q → %d, esperava %d"):format(
		i, ca[1], ca[2], got, ca[3]))
end
-- registro de estilo + satisfaz na língua do HOST (o requisito novo da 0.2
-- era conferir versão do doador contra a do host SEM sair da própria língua)
assert(version.cmp("xbps", "2.41_2", "2.38") > 0, "xbps: 2.41_2 > 2.38")
assert(version.cmp("xbps", "2.38", "2.41_2") < 0, "xbps: 2.38 < 2.41_2")
assert(version.satisfies("xbps", "2.41_2", ">=", "2.38"), "satisfies xbps")
assert(version.satisfies("xbps", "2.30_1", ">=", "2.38") == false, "satisfies xbps neg")

print("test_version: OK")
