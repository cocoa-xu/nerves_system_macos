.PHONY: validate

validate:
	mix format --check-formatted
	mix compile --warnings-as-errors
	@for script in priv/scripts/*.sh priv/guest/*.sh; do /bin/bash -n "$$script" || exit; done
