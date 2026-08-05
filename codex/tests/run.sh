#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bash "${TEST_DIR}/test_wrapper.sh"
bash "${TEST_DIR}/test_prestart.sh"
bash "${TEST_DIR}/test_profiles.sh"
bash "${TEST_DIR}/test_login.sh"
python3 "${TEST_DIR}/test_compose.py"
