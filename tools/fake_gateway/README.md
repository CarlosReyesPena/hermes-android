# Synthetic Desktop Gateway

This local-only fixture exercises the Dashboard and Desktop Gateway contracts
used by the Android application. All sessions, credentials, prompts, files, and
responses are synthetic.

## Run

```bash
python -m pip install -r requirements.txt
python fake_gateway.py --host 127.0.0.1 --port 18642 --api-key test-key
```

In another terminal:

```bash
python test_fake_gateway.py
```

The fixture binds to loopback by default. Do not expose it as a real gateway or
reuse its synthetic credentials for any other service.
