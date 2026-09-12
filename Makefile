.PHONY: validate

validate:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix test
	python3 -m unittest discover -s test -p '*_test.py'
	@for script in priv/scripts/*.sh priv/guest/*.sh; do /bin/bash -n "$$script" || exit; done
