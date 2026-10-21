-- profiles/void.lua
--
-- Perfil de host razoável para a primeira build: VOID LINUX.
--
-- Por que void + arch é o melhor par da matriz toda:
--   * ambos rolling -> glibc em passos quase iguais, sem a dor de "doador
--     nunca pode ser mais novo que o host" virar violação semanal;
--   * ambos usam /usr/bin direto (usrmerge feita há anos);
--   * xbps aceita binários .xbps; o lpm CONVERTE pacotes do pacman (.pkg.tar.zst)
--     em .xbps ANTES de instalar, e quem decide conflitos de arquivo e a
--     limpeza é sempre o xbps, nunca o lpm.
--
-- Regra global gravada no README: o DOADOR nunca é mais novo que o HOST.
-- void(rolling) <- arch(rolling) respeita isso por construção.

return {
	id = "void",
	pm = "xbps",

	donor = {
		id = "arch",
		style = "pacman",        -- língua de versão do doador
		db_dir = "~/.cache/lpm/arch",
		-- base do espelho (v1.1): o config/CLI troca a base e os paths
		-- do repositório ficam intactos (todas as mirror-farmas do Arch
		-- publicam o MESMO caminho atrás da base)
		mirror = "https://geo.mirror.pkgbuild.com",
		repos = {
			{
				id = "core",
				path = "/core/os/x86_64/core.db",
			},
			{
				id = "extra",
				path = "/extra/os/x86_64/extra.db",
			},
		},
		-- pacote .pkg.tar.zst vive ao lado do .db
		file_url_template = "%MIRROR%/%REPO%/os/x86_64/%FILENAME%",
	},

	install_repo_dir = "~/.cache/lpm/converted", -- .xbps convertidos + INDEX
	dry_default = true,                          -- v0.1: nada é instalado sem --yes

	-- v0.3: doadores alternativos (o CLI escolhe com --donor=<id>; arch
	-- segue o padrão). Debian entra como fonte de libs estáveis: STABLE é
	-- mais velho que o rolling do Void POR CONSTRUÇÃO — a regra central
	-- ("o doador nunca é mais novo que o host") nunca é violada por sync.
	donors = {
		debian = {
			id = "debian",
			style = "deb",        -- língua de versão dpkg
			module = "debian",    -- lpm/repos/debian.lua
			db_dir = "~/.cache/lpm/debian",
			stage_style = "deb",  -- payload = ar (.deb): repos.debian.stage
			mirror = "https://deb.debian.org/debian",
			repos = {
				{
					id = "stable-main",
					path = "/dists/stable/main/binary-amd64/Packages.gz",
				},
			},
			-- o Filename do índice é relativo à base do repositório
			file_url_template = "%MIRROR%/%FILENAME%",
		},
	},
}