-- tests/test_repos.lua -- parser do banco do pacman e índice debian.
--
-- O fixture é um .db de verdade em estrutura: tar com <pkgdir>/{desc,depends},
-- apinhado pelo mesmo formato que o pacman observa. Aqui em tar cru porque xz
-- não está na máquina de dev; no Void o tar dele detecta xz/zstd normal.

local util = require("lpm.util")
local arch = require("lpm/repos/arch")
local debian = require("lpm/repos/debian")

local tmp = "/tmp/opencode/lpm-test-" .. tostring(os.time())
util.makedirs(tmp)
local dbsrc = tmp .. "/db"
local exdir = tmp .. "/extracted"

local desc = [[
%FILENAME%
hello-2.10_2-x86_64.pkg.tar.zst

%NAME%
hello

%BASE%
hello

%VERSION%
2.10_2

%DESC%
A program that produces a familiar, friendly greeting

%SHA256SUM%
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

%ARCH%
x86_64

%LICENSE%
GPL

%URL%
https://www.gnu.org/software/hello/

%PROVIDES%
greeting

%CONFLICTS%
greeting
]]

local depends = [[
%DEPENDS%
glibc>=2.38

%OPTDEPENDS%
docs: Leaf
]]

local gdesc = [[
%FILENAME%
gcc-14.2.1-1-x86_64.pkg.tar.zst

%NAME%
gcc

%VERSION%
14.2.1

%DESC%
The GNU Compiler Collection

%ARCH%
x86_64
]]
local gdeps = [[
%DEPENDS%
glibc>=2.38
isl
libisl.so=23-64
]]

-- monta o fixture .db
util.makedirs(dbsrc .. "/hello")
util.makedirs(dbsrc .. "/gcc")
assert(util.write_file(dbsrc .. "/hello/desc", desc))
assert(util.write_file(dbsrc .. "/hello/depends", depends))
assert(util.write_file(dbsrc .. "/gcc/desc", gdesc))
assert(util.write_file(dbsrc .. "/gcc/depends", gdeps))

-- formato NOVO dos .db do Arch (2025+): %DEPENDS% vem dentro do próprio
-- `desc`, sem arquivo depends separado
local cdesc = [[
%FILENAME%
cpio-2.15-3-x86_64.pkg.tar.zst

%NAME%
cpio

%VERSION%
2.15-3

%DESC%
A tool to copy files into or out of a cpio or tar archive

%DEPENDS%
glibc
]]
util.makedirs(dbsrc .. "/cpio")
assert(util.write_file(dbsrc .. "/cpio/desc", cdesc))

assert(util.sh(("tar -cf '%s' -C '%s' '%s' '%s' '%s'"):format(tmp .. "/core.db", dbsrc, "hello", "gcc", "cpio")) == 0)

-- extração e índice ------------------------------------------------------
assert(arch.extract_db(tmp .. "/core.db", exdir))
local idx = assert(arch.build_index(exdir))

local hel = idx.by_name["hello"]
assert(hel, "hello indexado")
assert(hel.version == "2.10_2", "versão lida do %VERSION%")
assert(hel.desc:find("familiar", 1, true), "DESC lida")
assert(#hel.provides == 1 and hel.provides[1] == "greeting", "PROVIDES lida")
assert(#hel.depends == 1 and hel.depends[1].name == "glibc", "DEPENDS parseada com sysname")
assert(hel.depends[1].op == ">=" and hel.depends[1].ver == "2.38", "constraint da dep")
assert(idx.by_provides["greeting"] == hel, "índice de provides")

local gcc = idx.by_name["gcc"]
assert(#gcc.depends == 3, "3 deps do gcc")
assert(gcc.depends[3].name == "libisl.so", "lib de sonome parseada")
assert(gcc.depends[3].ver == "23-64", "versão de soname lida")

local cpio = idx.by_name["cpio"]
assert(cpio, "cpio indexado")
assert(#cpio.depends == 1 and cpio.depends[1].name == "glibc",
	"DEPENDS embutida no desc do formato novo é lida")

-- parser do campo debian --------------------------------------------------
local packages = [[
Package: hello
Version: 2.10-3
Architecture: amd64
Depends: libc6 (>= 2.34), gcc-14-base
Provides: greeting
Description: familiar greeting program
 multi-line continuation here too
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

Package: other
Version: 1.0-1
Depends: hello
Description: other thing
]]
local didx = debian.build_index(packages)
local dhel = didx.by_name["hello"]
assert(dhel, "hello debian indexado")
assert(dhel.version == "2.10-3", "versão debian")
assert(#dhel.depends == 2, "2 deps debian")
assert(dhel.depends[1].name == "libc6" and dhel.depends[1].op == ">=" and dhel.depends[1].ver == "2.34",
	"dep debian com constraint")
assert(dhel.desc == "familiar greeting program", "primeira linha da descrição")
assert(dhel.sha256 == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
	"sha256 debian")
assert(didx.by_provides["greeting"] == dhel, "provides debian")

-- preflight ----------------------------------------------------------------
local preflight = require("lpm.preflight")
local installed_map = { glibc = "2.41_2", isl = "0.27_1" }
local ok, issues = preflight.check_deps(hel, installed_map, "pacman", "xbps")
assert(ok, "hello cabe: " .. table.concat(issues, "; "))

local ok2, issues2 = preflight.check_deps(gcc, installed_map, "pacman", "xbps")
assert(ok2, "gcc cabe: " .. table.concat(issues2, "; "))
assert(#issues2 == 1 and issues2[1]:find("libisl.so", 1, true),
	"dep de soname vira aviso, não bloqueio")

local bad = { glibc = "2.30_1" }
local ok3, issues3 = preflight.check_deps(gcc, bad, "pacman", "xbps")
assert(ok3 == false, "gcc trava sem isl")
assert(#issues3 == 3, "glibc velho + isl ausente (bloqueios) + soname (aviso)")
assert(issues3[1]:find("insufficient version", 1, true), "glibc velho avisado")
assert(issues3[2]:find("isl", 1, true), "aviso nomeia o faltante")

local ok4, issues4 = preflight.check_deps(hel, { glibc = "2.30_1" }, "pacman", "xbps")
assert(ok4 == false, "glibc 2.30 < 2.38 trava")
assert(issues4[1]:find("insufficient version", 1, true), "aviso de versão insuficiente")

-- soname com mapa de shlibs do host (novo da 0.2): sem provedor BLOQUEIA
local semisl = { ["libc.so.6"] = "glibc" }
local ok5, issues5 = preflight.check_deps(gcc, installed_map, "pacman", "xbps", semisl)
assert(ok5 == false, "gcc trava sem provedor de libisl.so.23 (com mapa)")
assert(#issues5 == 1 and issues5[1]:find("libisl%.so%.23", 1, false),
	"bloqueio nom o soname real (23-64 → .23)")

local comisl = { ["libc.so.6"] = "glibc", ["libisl.so.23"] = "isl" }
local ok5b, issues5b = preflight.check_deps(gcc, installed_map, "pacman", "xbps", comisl)
assert(ok5b, "gcc cabe com provedor de libisl.so.23: " .. table.concat(issues5b, "; "))

-- check_elf (payload real): regra central por pacote -----------------------
local scan_tbel = { elf = 2, needed = {}, needed_names = { "libc.so.6" }, self = {}, glibc_min = "2.50" }
local ok6, blocos6 = preflight.check_elf("eq", scan_tbel, semisl, "2.41_1")
assert(ok6 == false and #blocos6 == 1 and blocos6[1]:find("glibc 2.50", 1, true),
	"ABI: doador mais novo que host BLOQUEIA para transfusão")

scan_tbel.glibc_min = "2.34"
local ok6b, blocos6b, avisos6b = preflight.check_elf("eq", scan_tbel, semisl, "2.41_1")
assert(ok6b and #blocos6b == 0, "ABI ok quando glibc do host >= exigida")

local scan_vazio = { elf = 0, needed = {}, needed_names = {}, self = {}, glibc_min = nil }
local ok6c, _, avisos6c = preflight.check_elf("scripts", scan_vazio, semisl, "2.41_1")
assert(ok6c and #avisos6c == 1, "payload sem ELF é aviso, não bloqueio")

-- self-provido (DT_SONAME do próprio payload) não é do host
scan_vazio.elf = 1
scan_vazio.needed_names = { "libx.so.1" }
scan_vazio.self = { ["libx.so.1"] = true }
local ok6d, blocos6d = preflight.check_elf("plugin", scan_vazio, semisl, "2.41_1")
assert(ok6d and #blocos6d == 0, "soname próprio do payload não bloqueia")

-- v2.0.3: órfão só passa QUANDO o usuário declara (--orphan); sem a
-- declaração o bloqueio continua (honestidade > conveniência)
local scan_orfao = { elf = 1, needed = {}, needed_names = { "libhspell.so.0" }, self = {}, glibc_min = nil }
local ok6e, blocos6e = preflight.check_elf("enchant", scan_orfao, semisl, "2.41_1")
assert(ok6e == false and #blocos6e == 1 and blocos6e[1]:find("libhspell", 1, true),
	"órfão sem --orphan continua BLOQUEANDO")
local ok6f, blocos6f, avisos6f = preflight.check_elf("enchant", scan_orfao, semisl, "2.41_1", nil,
	{ ["libhspell.so.0"] = true })
assert(ok6f and #blocos6f == 0, "órfão declarado em --orphan não bloqueia")
assert(#avisos6f == 1 and avisos6f[1]:find("orphan allowed", 1, true),
	"órfão declarado vira aviso explícito (nada em silêncio)")

-- aliases (v1.2.1: 'libc6→glibc' é AUTOMÁTICO agora — via reconstrução do
-- soname 'libc.so.6', que é a verdade mesmo; cada map do host decide)
local aliases = require("lpm.aliases")
assert(preflight.deboname_soname("zlib1g") == nil,
	"zlib1g não é reconstrução: fica na tabela como override")
assert(preflight.across("libc6", "deb") == "libc6",
	"sem tabela: nomes caem neles mesmos (o automático fecha o resto)")
assert(preflight.deboname_satisfied("libc6",
	{ ["libc.so.6"] = "glibc" }) == "glibc", "libc6 é glibc (automático)")
assert(preflight.across(" glibc", "deb") == " glibc" or true,
	"across fallback não levanta")

-- util.dump round-trip ------------------------------------------------------
local dump = tmp .. "/idx.lua"
assert(util.save({ a = { "x", "y" } }, dump))
local back = assert(util.load(dump))
assert(back.a[1] == "x" and back.a[2] == "y", "save/load de tabela")

util.sh("rm -rf -- '" .. tmp .. "'")
print("test_repos: OK")
