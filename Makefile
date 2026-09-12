.PHONY: validate

validate:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix test
	python3 -m unittest discover -s test -p '*_test.py'
	/bin/bash -n priv/scripts/provision.sh priv/guest/verify-system.sh priv/guest/install-release.sh priv/guest/verify-release.sh
