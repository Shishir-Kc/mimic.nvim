local java_configs = {
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
  "settings.gradle",
  "settings.gradle.kts",
  "build.xml",
  ".project",
  ".classpath",
}

return {
  {
    id = "jdtls",
    label = "jdtls",
    languages = { "java" },
    categories = {
      lsp = {
        server = "jdtls",
        role = "language",
        executable = "jdtls",
        mason = "jdtls",
        covers = { format = true },
        requires_plugin = "nvim-jdtls",
        starter = "nvim-jdtls",
      },
    },
    config_files = java_configs,
    priority = { lsp = 100 },
  },
  {
    id = "checkstyle",
    label = "Checkstyle",
    languages = { "java" },
    categories = {
      lint = {
        linter = "checkstyle",
        executable = "checkstyle",
        mason = "checkstyle",
      },
    },
    config_files = {
      "checkstyle.xml",
      ".checkstyle",
      "checkstyle/checkstyle.xml",
      "config/checkstyle/checkstyle.xml",
    },
    requires_config = true,
    priority = { lint = 100 },
  },
  {
    id = "google_java_format",
    label = "google-java-format",
    languages = { "java" },
    categories = {
      format = {
        formatters = { "google-java-format" },
        executable = "google-java-format",
        mason = "google-java-format",
      },
    },
    priority = { format = 50 },
  },
}
