@rust @rust-3 @cleanup-review @cleanup-config-review
Feature: Cleanup policy configuration errors
  Invalid cleanup policies identify the setting and its accepted values.

  Scenario Outline: Invalid <scope> cleanup policy <value> in <format>
    When I run shell command:
      """
      python3 - <<'PY'
      import subprocess
      import sys
      import tempfile

      value = '<value>'
      scope = '<scope>'
      if '<format>' == 'toml':
          content = '[general]\nadmin_username = "admin"\nadmin_password = "admin"\n'
          if scope == 'pool':
              content += '[pools.example_db]\n'
          content += f'cleanup_server_connections = {value}\n'
      else:
          content = 'general:\n  admin_username: admin\n  admin_password: admin\n'
          if scope == 'pool':
              content += 'pools:\n  example_db:\n'
          indent = '    ' if scope == 'pool' else '  '
          content += f'{indent}cleanup_server_connections: {value}\n'

      with tempfile.NamedTemporaryFile(mode='w', suffix='.<format>') as config:
          config.write(content)
          config.flush()
          result = subprocess.run(
              ['${DOORMAN_BINARY}', '-t', config.name],
              capture_output=True, text=True, timeout=10,
          )
          print(result.stdout + result.stderr)
          sys.exit(result.returncode)
      PY
      """
    Then the command should fail
    And the command output should contain "cleanup_server_connections"
    And the command output should contain "expected a boolean or one of: off, adaptive, always"

    Examples:
      | format | scope   | value  |
      | toml   | general | 1      |
      | toml   | general | [true] |
      | toml   | general | "auto" |
      | toml   | pool    | 1      |
      | toml   | pool    | [true] |
      | toml   | pool    | "auto" |
      | yaml   | general | 1      |
      | yaml   | general | [true] |
      | yaml   | general | "auto" |
      | yaml   | pool    | 1      |
      | yaml   | pool    | [true] |
      | yaml   | pool    | "auto" |
