-- tests/test_bridge.lua -- v2.0: PONTE automática donor→host pelo repodata
-- do próprio repositório do xbps (shlib-provides/provides por pacote) e as
-- camadas novas: host_component_pkg (maioria), repo_shlibs/repo_provides na
-- chain e a tradução da dep no .xbps (gtk3 → gtk+3). Fixtures 100% fake —
-- sem rede, sem /var/db.
--
-- Formato testado é o MESMO da plist do pkgdb (uma chave de 1 tab por
-- pacote, props a 2 tabs, arrays de <string>) — a C trap é o array
-- 'shlib-REQUIRES' (o parser tem que escopar o campo: só provides entram).

local here = (arg and arg[0]) or "tests/test_bridge.lua"
local root = (here:match("^(.-)/?tests/") or ".")
package.path = root .. "/?.lua;" .. package.path

local pmxbps = require("lpm.pm.xbps")
local preflight = require("lpm.preflight")
local chain = require("lpm.chain")
local convert = require("lpm.convert")

-- ====== 1. scan_plist: repodata textual → {shlibs, provides} por pacote ===
local repodata = [[
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>gtk+3</key>
	<dict>
		<key>architecture</key>
		<string>x86_64</string>
		<key>pkgver</key>
		<string>gtk+3-3.24.43_1</string>
		<key>run_depends</key>
		<array>
			<string>glib-2.0-so-something</string>
		</array>
		<key>shlib-provides</key>
		<array>
			<string>libgdk-3.so.0</string>
			<string>libgtk-3.so.0</string>
		</array>
		<key>shlib-requires</key>
		<array>
			<string>libX11.so.6</string>
		</array>
	</dict>
	<key>libssl3</key>
	<dict>
		<key>pkgver</key>
		<string>libssl3-3.5.4_1</string>
		<key>shlib-provides</key>
		<array>
			<string>libssl.so.3</string>
		</array>
		<key>provides</key>
		<array>
			<string>openssl-1.1.2_1</string>
		</array>
	</dict>
	<key>yash</key>
	<dict>
		<key>pkgver</key>
		<string>yash-2.63_1</string>
		<key>provides</key>
		<array>
			<string>cmd:sh-0_1</string>
		</array>
	</dict>
</dict>
</plist>
]]
local i, s, p = pmxbps.scan_plist(repodata, "(?)")
assert(i["gtk+3"] == "3.24.43_1", "pkgver parsed: " .. tostring(i["gtk+3"]))
assert(s["libgtk-3.so.0"] == "gtk+3", "shlib-provides entra: " ..
	tostring(s["libgtk-3.so.0"]))
assert(s["libssl.so.3"] == "libssl3", "segundo pacote: " .. tostring(s["libssl.so.3"]))
-- A TRAP: shlib-REQUIRES NÃO pode envenenar o mapa de provides
assert(s["libX11.so.6"] == nil, "requires de outro campo NÃO vira provide")
assert(p["sh"] == "yash", "provide 'cmd:sh-0_1' indexado como 'sh': " ..
	tostring(p["sh"]))
assert(p["openssl"] == "libssl3", "provide de nome cru indexado")
assert(p["lib"] == nil and p["glib-2.0-so-something"] == nil,
	"run_depends/strings de campos irrrelevantes não poluem nada")

-- ====== 2. host_component_pkg: TODOS os sonames + MAIORIA ======
local donor_gtk3 = {
	name = "gtk3", version = "3.24.43-1",
	provides = { "libgtk-3.so=0-3.24", "libgdk-3.so=0-3.24" },
}
assert(preflight.host_component_pkg(donor_gtk3, s) == "gtk+3",
	"componente: todos os sonames do provedor batem num único host-pkg: " ..
	tostring(preflight.host_component_pkg(donor_gtk3, s)))
-- um soname FORA do host → nada automático (split diferente)
local donor_with_extra = {
	name = "weird", version = "1-1",
	provides = { "libgtk-3.so=0-3.24", "libnaoexiste.so=9-9" },
}
assert(preflight.host_component_pkg(donor_with_extra, s) == nil,
	"parcial = nil: não se prova o mesmo componente")
-- maioria: 2 sonames → gtk+3, 1 → libssl3; gtk+3 vence (empate → o
-- menor nome vence, determinismo)
local donor_maj = {
	name = "maj", version = "1-1",
	provides = { "libgtk-3.so=0", "libgdk-3.so=0", "libssl.so=3" },
}
assert(preflight.host_component_pkg(donor_maj, s) == "gtk+3",
	"maioria determina o componente: " ..
	tostring(preflight.host_component_pkg(donor_maj, s)))
-- sem sonames declarados → nil (nada automático)
assert(preflight.host_component_pkg({ name = "x", provides = {} }, s) == nil,
	"provedor mudo não corrobora")
assert(preflight.host_component_pkg(nil, s) == nil, "nil-safe")

-- ====== 3. chain: ponte REPO fecha a dep SEM converter (e anota solved) ====
local arch_gtk3 = {
	name = "gtk3", version = "3.24.43-1", repo = "extra",
	provides = { "libgtk-3.so=0-3.24", "libgdk-3.so=0-3.24" }, depends = {},
}
local pl = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "libnaosabe" } } } }, {
		-- repodata disponível (s/p), MAS a dep não existe em lugar nenhum:
		-- a ponte NUNCA inventa provider — bloqueia honesto
		search = function() return nil end,
		installed = {}, shlibs = nil,
		repo_shlibs = s, repo_provides = p,
		donor_style = "deb", host_style = "xbps", allow_private = true,
	})
assert(not pl.ok, "sem provider em LUGAR NENHUM: bloqueia honesto")
assert(#pl.issues == 1 and (pl.issues[1] or ""):find("libnaosabe", 1, true),
	"issue honesta da dep certa (a ponte não tapa o sol)")
assert(next(pl.solved or {}) == nil, "nada anotado em solved")

-- agora com o provider CERTO no doador (por nome): camada B sobre repo
local pl2 = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "gtk3" } } } }, {
		search = function(n, via)
			return (n == "gtk3" and not via) and arch_gtk3 or nil
		end,
		installed = {}, shlibs = nil, -- host NEM tem o mapa de instalados!
		repo_shlibs = s, repo_provides = p,
		donor_style = "deb", host_style = "xbps", allow_private = true,
	})
assert(pl2.ok, "ponte repo fecha: " .. table.concat(pl2.issues, " | "))
assert(#pl2.ordered == 1 and pl2.ordered[1].name == "app",
	"o provedor do doador NEM entra no plano (trabalho zero): " ..
	#pl2.ordered)
assert((pl2.solved or {})["gtk3"] == "gtk+3",
	"plan.solved anota a tradução: " .. tostring(pl2.solved["gtk3"]))

-- provide de repo virtual: dep 'sh' fecha só (solver nativo casa provides)
local pl3 = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "sh" } } } }, {
		search = function() return nil end,
		installed = {}, shlibs = nil,
		repo_shlibs = s, repo_provides = p,
		donor_style = "deb", host_style = "xbps",
	})
assert(pl3.ok and #pl3.ordered == 1, "repo_provides fecha virtual: " ..
	table.concat(pl3.issues, " | "))

-- ====== 4. convert.host_deps: solved PRIMEIRO; repo_map por último recurso
local out = convert.host_deps(
	{ name = "app", depends = { { name = "gtk3" } } },
	"xbps", nil,
	{ ["gtk3"] = "gtk+3" },  -- o plano provou: gtk3 → gtk+3
	s)                        -- repodata à mão, mas não é o que decide aqui
assert(out[1] == "gtk+3>=0", "solved traduz a dep do .xbps: " .. out[1])

-- sem solved: repodata traduz SÓ (nome cru igual ao doador → sem rewrite,
-- o solver DESTE pacote decide a versão no repo nativo)
local out2 = convert.host_deps(
	{ name = "app", depends = { { name = "libssl3" } } },
	"xbps", nil, nil, s)
assert(out2[1] == "libssl3>=0", "repodata traduz ao próprio nome: " .. out2[1])

-- dep sem ponte nenhuma sai CRUA (honesto: o solver do host decide)
local out3 = convert.host_deps(
	{ name = "app", depends = { { name = "libc6", op = ">=", ver = "2.34" } } },
	"xbps", nil, nil, s)
assert(out3[1] == "libc6>=2.34_1", "sem testemunha: crua e honesta (revisão garantida): " .. out3[1])

-- o mapa da TRANSAÇÃO (com marca '*' de bolha) continua NA FRENTE de tudo:
-- a dep que a bolha privada resolve NEM ENTRA no .xbps
local txmap = {}
txmap["libgtk-3.so.0"] = "(*payload app)"
local out4 = convert.host_deps(
	{ name = "app", depends = { { name = "libgtk-3-0" } } },
	"xbps", txmap, nil, s)
assert(#out4 == 0, "bolha privada vence repodata (a dep SOME): " ..
	table.concat(out4, " "))

-- ====== 5. satisfação via repo_shlibs não PESA no caminho INSTALADO ======
-- após a instade da 1.2.1: com o mapa instalado presente E a ponte, a
-- camada A produz plan.solved MESMO para nomes cujo host-pkg é igual
local pl5 = chain.plan(
	{ { name = "app", version = "1-1", repo = "extra",
		depends = { { name = "libssl3" } } } }, {
		search = function() return nil end,
		installed = {},                    -- NEM instalado, nem mapa: SÓ repo
		shlibs = nil, repo_shlibs = s, repo_provides = p,
		donor_style = "deb", host_style = "xbps",
	})
assert(pl5.ok, "camada A via repodata: " ..
	table.concat(pl5.issues, " | "))
assert((pl5.solved or {})["libssl3"] == "libssl3",
	"solved anota o host-pkg (mesmo igual ao nome pedido): " ..
	tostring(pl5.solved["libssl3"]))

print("test_bridge: OK")
