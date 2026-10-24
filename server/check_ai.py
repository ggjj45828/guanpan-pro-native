"""Explicit NAS-side DeepSeek connectivity check; never prints the API key."""
import json
import sys
from ai import AIProviderError, provider_status, verify_provider


def main():
    status = provider_status()
    if not status["configured"]:
        print(json.dumps(status, ensure_ascii=False))
        return 2
    try:
        result = verify_provider()
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except AIProviderError as error:
        safe = {"state": "failed", "profile": status["profile"], "model": status["model"], "message": str(error)}
        print(json.dumps(safe, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
