-- tests/test_elf.lua -- parser ELF puro Lua: DT_NEEDED + DT_SONAME +
-- requisição máxima de GLIBC_ (via .gnu.version_r).
--
-- Fixture: um ELF real da máquina quando houver (/usr/bin/ls é constante
-- de qualquer Linux; na máquina de dev, Void). Sem ELF disponível o
-- arquivo termina em silêncio (o runner registra OK do arquivo vazio).

local here = (arg and arg[0]) or "tests/test_version.lua"
local root = here:match("^(.-)/?tests/") or "."
package.path = root .. "/?.lua;" .. package.path

local util = require("lpm.util")
local elf = require("lpm.elf")

-- /usr/bin/ls existe em qualquer Sistema-alvo; ysem ELF fora do alcance
-- (big-endian) cai como skipped, sem erro.
if not util.file_exists("/usr/bin/ls") then return end

local scan = elf.scan("/usr/bin")
assert(scan.elf >= 1, "pelo menos 1 ELF parseado em /usr/bin")
assert((scan.needed["libc.so.6"] or 0) >= 1, "ls precisa de libc.so.6 (DT_NEEDED)")
-- glibc_min: ls usa versões de GLIBC_ geralmente; pode ser nil em builds
-- muito simples, então only-consistencia: se presente, tem formato sã
if scan.glibc_min then
	assert(scan.glibc_min:match("^%d+%.%d+$"), "formato de versão GLIBC: " .. scan.glibc_min)
end

-- payload de binário que não existe → vazio, sem explodir
local vazio = elf.scan("/tmp/opencode/nao-existe-" .. os.time())
assert(vazio.elf == 0, "diretório inexistente: zero ELFs")

-- gêmeos de plataforma (v2.0.2): twin musl é prunado SOMENTE quando o irmão
-- glibc existe; sem irmão, o scan não descarta nada.
local base = "/tmp/opencode/test_elf_twins"
os.execute("rm -rf " .. base)
os.execute("mkdir -p " .. base .. "/pkg/parcelwatcher-linux-x64-glibc "
	.. base .. "/pkg/parcelwatcher-linux-x64-musl "
	.. base .. "/sozinho/parcelwatcher-linux-x64-musl")
os.execute("cp /usr/bin/ls " .. base .. "/pkg/parcelwatcher-linux-x64-glibc/watcher.node")
os.execute("cp /usr/bin/ls " .. base .. "/pkg/parcelwatcher-linux-x64-musl/watcher.node")
os.execute("cp /usr/bin/ls " .. base .. "/sozinho/parcelwatcher-linux-x64-musl/watcher.node")

local com_irmao = elf.scan(base .. "/pkg")
assert(com_irmao.elf == 1, "twin musl prunado: só o ELF do twin glibc conta (" .. tostring(com_irmao.elf) .. ")")
assert(com_irmao.skipped_twins == 1, "1 pruno contabilizado")
assert(#com_irmao.excluded_twins == 1, "lista de excluídos registra o caminho")
assert(com_irmao.excluded_twins[1]:match("linux%-x64%-musl"), "excluído é o caminho musl")
assert((com_irmao.needed["libc.so.6"] or 0) >= 1, "needed agregado segue falando")

local sem_irmao = elf.scan(base .. "/sozinho")
assert(sem_irmao.elf == 1, "sem irmão glibc o musl NÃO é prunado (incompatibilidade tem que falar)")
assert((sem_irmao.skipped_twins or 0) == 0, "sem irmão: nenhum pruno")

os.execute("rm -rf " .. base)

print("test_elf: OK")
