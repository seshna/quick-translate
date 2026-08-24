# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through this repository's
GitHub Security Advisories page. Do not include sensitive translation text in
the report.

Quick Translate sends entered text to the selected translation provider. Google,
Apertium, Bing, and Reverso use unofficial public web endpoints over HTTPS;
OpenAI uses its HTTPS API; and Ollama uses the local service on `localhost`.
Translation contexts are also sent to OpenAI when it is selected. Do not use
remote providers for confidential or sensitive content.
