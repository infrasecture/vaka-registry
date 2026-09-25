# Keep the multi-architecture upstream release immutable; no provider calls.
FROM docker.litellm.ai/berriai/litellm:v1.104.0-dev.1@sha256:3def0387871a732a6d18b009576c4bf4313c54d448fa938a58f51cf189d1fa33
COPY patch_chatgpt.py /tmp/patch_chatgpt.py
RUN LITELLM_LOCAL_MODEL_COST_MAP=True python /tmp/patch_chatgpt.py \
    && rm /tmp/patch_chatgpt.py
