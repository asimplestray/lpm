-- tests/run.lua -- runner mínimo: cada test_*.lua é um script com asserts.
-- Uso: bin/lpm executa `lua tests/run.lua` (ou: lua tests/run.lua [files...])

local here = (arg and arg[0]) or "tests/run.lua"
local root = (here:match("^(.-)/?tests/run%.lua$") or ".")
if root == "" then root = "." end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local files = {}
if arg and #arg > 1 then
	for i = 2, #arg do files[#files + 1] = arg[i] end
else
	local ls = io.popen("ls -1 " .. root .. "/tests/ 2>/dev/null")
	assert(ls, "não consegui listar " .. root .. "/tests/")
	for f in ls:read("*a"):gmatch("[^\r\n]+") do
		if f:match("^test_.*%.lua$") then
			files[#files + 1] = root .. "/tests/" .. f
		end
	end
end

local failures = 0
for _, path in ipairs(files) do
	local chunk, err = loadfile(path, "t")
	if not chunk then
		print("ERRO: não carregou " .. path .. ": " .. tostring(err))
		failures = failures + 1
	else
		print("== " .. path)
		local ok, err2 = pcall(chunk)
		if not ok then
			print("    FALHOU: " .. tostring(err2))
			failures = failures + 1
		end
	end
end

if failures == 0 then
	print("OK: todos os testes passaram")
	os.exit(0)
else
	print(("FALHOU %d arquivo(s) de teste"):format(failures))
	os.exit(1)
end
