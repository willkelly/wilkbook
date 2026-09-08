-- Test-copy override only. Each open receives one endpoint from a controlled
-- in-process socketpair; the production StateChannel remains unchanged.
return require("real_ui_socket_fixture").client
