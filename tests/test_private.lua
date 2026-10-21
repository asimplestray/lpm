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

-- ====== 5. fold_private: payload do doador entra /usr/lib/lpm/<pkg> ====
local tmp = "/tmp/opencode/lpm-priv-" .. tostring(os.time())
util.makedirs(tmp .. "/providers/libfoo/usr/lib")
util.write_file(tmp .. "/providers/libfoo/usr/lib/libfoo.so.2", "PAYLOAD")
local staged = tmp .. "/app"
util.makedirs(staged .. "/usr/bin")
local priv = {
	order = { "libfoo" },
	dirs = { libfoo = tmp .. "/providers/libfoo" },
	resolved = { ["libfoo.so.2"] = "libfoo" },
}
local dirs = convert.fold_private(staged, priv)
assert(dirs[1] == "/usr/lib/lpm/libfoo", "caminho relativo da bolha")
assert(util.read_file(staged .. "/usr/lib/lpm/libfoo/usr/lib/libfoo.so.2") == "PAYLOAD",
	"payload do provedor está DENTRO do staging do app")

-- ====== 6. wrap_bins: ELF em /usr/bin vira wrapper; script intacto ======
-- fixture: ELF real (cópia de /bin/dd) + script sh
util.write_file(staged .. "/usr/bin/scripty", "#!/bin/sh\necho hi\n")
util.sh("cp /bin/dd " .. "'" .. staged .. "/usr/bin/realbin'")
local wraps, werr = convert.wrap_bins(staged, "disc", dirs)
assert(wraps and not werr, "wrap ok: " .. tostring(werr))
assert(#wraps == 1 and wraps[1] == "/usr/bin/realbin", "só o ELF é embrulhado")
local w = util.read_file(staged .. "/usr/bin/realbin")
assert(w:find("#!/bin/sh", 1, true), "wrapper replace o ELF")
assert(w:find('LD_LIBRARY_PATH="/usr/lib/lpm/libfoo', 1, true),
	"wrapper seta o LD_LIBRARY_PATH da bolha")
assert(w:find('exec "/usr/libexec/lpm/disc/realbin"', 1, true),
	"wrapper executa o binário real")
local w2 = util.read_file(staged .. "/usr/bin/scripty")
assert(w2:find("echo hi", 1, true), "script não-ELF intocado")
assert(util.file_exists(staged .. "/usr/libexec/lpm/disc/realbin"),
	"binário real relojado dentro do payload")

util.sh("rm -rf '" .. tmp .. "'")
print("test_private: OK")
