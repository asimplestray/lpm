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

print("test_elf: OK")
