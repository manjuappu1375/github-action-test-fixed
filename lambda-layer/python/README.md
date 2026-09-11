# Lambda Layer source

Everything under this folder gets zipped as-is and published as a Lambda
Layer version by `scripts/provision.sh` (see `lambda.layer` in a config
file). For a Python runtime, AWS requires importable code to live under a
top-level `python/` folder inside the layer zip - which is exactly this
folder, so anything you put alongside this README becomes `import`-able
from your Lambda function once the layer is attached.

Example: add a file `mylib.py` here, then in your Lambda code:
```python
import mylib
```

If you have third-party pip dependencies instead of your own code, install
them directly into this folder before a provisioning run, e.g.:
```bash
pip install requests -t lambda-layer/python --platform manylinux2014_x86_64 --only-binary=:all:
```