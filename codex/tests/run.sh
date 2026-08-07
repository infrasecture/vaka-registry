#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bash "${TEST_DIR}/test_wrapper.sh"
bash "${TEST_DIR}/test_prestart.sh"
python3 "${TEST_DIR}/test_onboarding.py"
bash "${TEST_DIR}/test_profiles.sh"
bash "${TEST_DIR}/test_login.sh"
python3 "${TEST_DIR}/test_compose.py"
bash "${TEST_DIR}/test_gateway_auth.sh"
bash "${TEST_DIR}/test_chatgpt_gateway.sh"
