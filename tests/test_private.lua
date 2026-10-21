-- tests/test_private.lua -- v1.2: bolha privada (lib doadora que sombrearia
-- o nativo vira payload APPENDIX do pacote do app) + casamento de soname
-- por prefixo + dedupe de issues + fold/wrap do payload.
--
-- Fixtures FAKE: nada de rede, nada de xbps-create no caminho de teste.

local here = (arg and arg[0]) or "tests/test_private.lua"
local root = (here:match("^(.-)/?tests/") or ".")
package.path = root .. "/?.lua;" .. package.path

local chain = require("lpm.chain")
local preflight = require("lpm.preflight")
local convert = require("lpm.convert")
local util = require("lpm.util")

-- ============ 1. soname bare casa por PREFIXO no mapa do host ============
assert(preflight.map_satisfies({ ["libffi.so.8"] = "libffi" }, "libffi.so") == "libffi",
	"bare 'libffi.so' casa com 'libffi.so.8'")
assert(preflight.map_satisfies({ ["libffi.so.8"] = "libffi" }, "libffi.so.9") == nil,
	"'libffi.so.9' não casa (.so.9 ≠ .so.8+algo)")
assert(preflight.map_satisfies(nil, "libc.so.6") == nil, "sem mapa → nil")
assert(preflight.map_satisfies({ ["libc.so.6"] = "glibc" }, "libc.so.6") == "glibc",
	"match exato continua")

-- ====== 2. chain: soname de provedor que sombreia NATIVO, com allow_private
local E = {
	disc = { name = "disc", version = "1.0.16-1", repo = "extra",
		depends = { { name = "libzub.so" } } },
	zub = { name = "zub", version = "2.0-1", repo = "extra", depends = {} },
	libzub = { name = "libzub", version = "2.0-1", repo = "core",
		provides = { { name = "libzub.so" } }, depends = {} },
}
-- host TEM libzub (nativo), e o mapa de shlibs NÃO tem libzub.so
-- (é exatamente a classe que travava discord na mão do usuário)
local ctxP = {
	search = function(n, v)
		return v and (n == "libzub.so" and E.libzub or nil) or E[n]
	end,
	installed = { libzub = "1.9_1" },
	shlibs = { ["libc.so.6"] = "glibc" },
	donor_style = "pacman", host_style = "xbps",
	allow_private = true,
}
local pv = chain.plan({ E.disc }, ctxP)
assert(pv.ok, "bolha privada: plano segue sem abortar: " .. tostring(pv.issues[1]))
assert(pv.private_nodes.libzub, "provedor entra em private_nodes")
assert(pv.private["libzub.so"] and pv.private["libzub.so"].name == "libzub",
	"soname registrado como privado")
assert(#pv.ordered == 1 and pv.ordered[1].name == "disc",
	"o app segue sendo o único nó tx")

-- ====== 3. sem allow_private o comportamento antigo se mantém ======
local ctxOld = {}
for k, v in pairs(ctxP) do ctxOld[k] = v end
ctxOld.allow_private = nil
local po = chain.plan({ E.disc }, ctxOld)
assert(not po.ok, "sem allow_private: segue abortando (regressão)")
assert((po.issues[1] or ""):find("soname", 1, true) or
	(po.issues[1] or ""):find("would convert it over the native", 1, true),
	"mensagem honesta do bloqueio")

-- ====== 4. issue duplicada (mesma mensagem, dois caminhos de dep) ======
-- duas dep-NOME que resolvem o MESMO provedor que sombreia nativo: a
-- guarda do dfs dispara duas vezes com mensagem IDÊNTICA → uma issue só
-- (o caso real do usuário: libglvnd geminado na saída de discord)
local E2 = {
	r1 = { name = "r1", version = "1-1", repo = "extra", depends = {
		{ name = "zub" }, { name = "zublib" },
	} },
	zubso = { name = "libzub", version = "2.0-1", repo = "core", depends = {} },
}
local ctx2 = {
	search = function(n, v)
		return (n == "zub" or n == "zublib") and E2.zubso or nil
	end,
	installed = { libzub = "1.9_1" },
	shlibs = { ["libc.so.6"] = "glibc" },
	donor_style = "pacman", host_style = "xbps",
}
local pd = chain.plan({ E2.r1 }, ctx2)
assert(not pd.ok, "confirmado: bloqueia sem allow_private")
assert(#pd.issues == 1, ("issue deduplicada: %d (esperava 1): %s")
	:format(#pd.issues, table.concat(pd.issues, " | ")))

-- ====== 5. fold_private: payload do doador entra /usr/lib/lpm/<app>/<pkg>
local tmp = "/tmp/opencode/lpm-priv-" .. tostring(os.time())
util.makedirs(tmp .. "/providers/libfoo/usr/lib")
util.write_file(tmp .. "/providers/libfoo/usr/lib/libfoo.so.2", "PAYLOAD")
local staged = tmp .. "/app"
util.makedirs(staged .. "/usr/bin")
local priv = {
	order = { "libfoo" },
	dirs = { libfoo = tmp .. "/providers/libfoo" },
	resolved = { ["libfoo.so.2"] = "libfoo" },
	scan_needs = { libfoo = {} },
}
local dirs = convert.fold_private(staged, priv, "disc", { "libfoo.so.2" })
assert(dirs[1] == "/usr/lib/lpm/disc/libfoo/usr/lib",
	"LD_LIBRARY_PATH aponta para o usr/lib do payload, não para a raiz")
assert(util.read_file(staged .. "/usr/lib/lpm/disc/libfoo/usr/lib/libfoo.so.2") == "PAYLOAD",
	"payload do provedor está DENTRO do staging do app")

-- Dois consumidores do MESMO provedor não podem compartilhar caminho: o
-- xbps recusa a transação inteira ("file ... already installed by ...").
local staged2 = tmp .. "/app2"
util.makedirs(staged2 .. "/usr/bin")
local dirs2 = convert.fold_private(staged2, priv, "other", { "libfoo.so.2" })
assert(dirs2[1] == "/usr/lib/lpm/other/libfoo/usr/lib",
	"segundo consumidor ganha namespace próprio")
assert(util.file_exists(staged2 .. "/usr/lib/lpm/other/libfoo/usr/lib/libfoo.so.2"),
	"cópia do segundo consumidor existe")
assert(not util.file_exists(staged2 .. "/usr/lib/lpm/disc"),
	"o segundo consumidor não herda o namespace do primeiro")

-- A bolha de um app leva só o que ele pede (mais o fechamento transitivo),
-- não todos os provedores privados da transação.
util.makedirs(tmp .. "/providers/libbar/usr/lib")
util.write_file(tmp .. "/providers/libbar/usr/lib/libbar.so.1", "BAR")
local privc = {
	order = { "libfoo", "libbar", "libunused" },
	dirs = { libfoo = tmp .. "/providers/libfoo",
		libbar = tmp .. "/providers/libbar" },
	resolved = { ["libfoo.so.2"] = "libfoo", ["libbar.so.1"] = "libbar",
		["libunused.so"] = "libunused" },
	scan_needs = { libfoo = {}, libbar = { "libfoo.so.2" }, libunused = {} },
}
local staged3 = tmp .. "/app3"
util.makedirs(staged3 .. "/usr/bin")
local dirs3 = convert.fold_private(staged3, privc, "app3", { "libbar.so.1" })
assert(#dirs3 == 2, "fecha transitivo sem puxar provedor alheio: " .. #dirs3)
assert(util.file_exists(staged3 .. "/usr/lib/lpm/app3/libfoo/usr/lib/libfoo.so.2"),
	"dependência privada do provedor entra na bolha")
assert(not util.file_exists(staged3 .. "/usr/lib/lpm/app3/libunused"),
	"provedor privado não pedido fica fora")

-- ====== 6. wrap_bins: ELF em /usr/bin vira wrapper; script intacto ======
-- fixture: ELF real (cópia de /bin/dd) + script sh
util.write_file(staged .. "/usr/bin/scripty", "#!/bin/sh\necho hi\n")
util.sh("cp /bin/dd " .. "'" .. staged .. "/usr/bin/realbin'")
local wraps, werr = convert.wrap_bins(staged, "disc", dirs)
assert(wraps and not werr, "wrap ok: " .. tostring(werr))
assert(#wraps == 1 and wraps[1] == "/usr/bin/realbin", "só o ELF é embrulhado")
local w = util.read_file(staged .. "/usr/bin/realbin")
assert(w:find("#!/bin/sh", 1, true), "wrapper replace o ELF")
assert(w:find('LD_LIBRARY_PATH="/usr/lib/lpm/disc/libfoo/usr/lib', 1, true),
	"wrapper seta o LD_LIBRARY_PATH da bolha")
assert(w:find('exec "/usr/libexec/lpm/disc/realbin"', 1, true),
	"wrapper executa o binário real")
local w2 = util.read_file(staged .. "/usr/bin/scripty")
assert(w2:find("echo hi", 1, true), "script não-ELF intocado")
assert(util.file_exists(staged .. "/usr/libexec/lpm/disc/realbin"),
	"binário real relojado dentro do payload")

-- ====== 7. inject_private_env: script launcher também recebe a bolha ======
-- O binário real do electron42 é um script em /usr/bin; o wrapper de ELF
-- não o vê. O export precisa entrar no script, sem movê-lo.
util.write_file(staged .. "/usr/bin/launchy", "#!/bin/sh\necho launch\n")
util.write_file(staged .. "/usr/bin/pyscript",
	"#!/usr/bin/env python3\nprint('nope')\n")
util.sh("chmod 755 '" .. staged .. "/usr/bin/launchy' '" ..
	staged .. "/usr/bin/pyscript'")
local scripts = convert.inject_private_env(staged, dirs)
assert(scripts and #scripts == 1 and scripts[1] == "/usr/bin/launchy",
	"só script shell executável recebe env: " .. tostring(scripts and #scripts))
assert(not util.read_file(staged .. "/usr/bin/pyscript")
	:find("LD_LIBRARY_PATH", 1, true),
	"script Python não recebe export de shell")
local sb = util.read_file(staged .. "/usr/bin/launchy")
assert(sb:sub(1, 10) == "#!/bin/sh\n", "shebang continua na primeira linha")
assert(sb:find('LD_LIBRARY_PATH="/usr/lib/lpm/disc/libfoo', 1, true),
	"script exporta a bolha privada")
local again = convert.inject_private_env(staged, dirs)
assert(again and #again == 0, "injeção é idempotente (não duplica export)")
assert(not util.read_file(staged .. "/usr/bin/realbin")
	:find("generated by lpm: private donor", 1, true),
	"wrapper de ELF gerado pelo lpm não é reinjetado")

util.sh("rm -rf '" .. tmp .. "'")
print("test_private: OK")
