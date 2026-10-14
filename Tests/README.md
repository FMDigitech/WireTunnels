Run the regression suites on macOS with Xcode command line tools and Python 3:

```sh
python3 Tests/run_tests.py
```

The tests use synthetic keys, addresses, configs, processes, and Unix sockets. They do not change system DNS or connect a VPN. Build products are created in a temporary directory.

Some execution sandboxes block child process inspection or Unix socket creation. Run the suites in a normal terminal when those restrictions produce an Operation not permitted error.

The shell tests use an unmodified upstream Darwin wg-quick fixture. Its source URL, pinned commit, and SHA-256 are recorded in `Fixtures/wg-quick-source.json`. The file retains its upstream GPL-2.0 SPDX identifier and copyright notice. Update the fixture and metadata when changing the tools revision in `Scripts/wireguard-versions.env`.
