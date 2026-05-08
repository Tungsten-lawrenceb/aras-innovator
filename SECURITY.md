# Security notes

This repo contains configuration for an Aras Innovator install. Treat it as
production-adjacent IP.

## What is NOT in this repo (and shouldn't be)

* The Entra App Registration client **secret value**.
* Aras account passwords (DB, root/admin, etc).
* The ngrok agent **authtoken**.

The corresponding placeholders are wired into `apply-customizations.ps1` as
parameters. Pass them at run time, never commit them.

## What IS in this repo (and is fine)

* Entra **tenant ID** and **client ID** — these are public identifiers, not
  secrets. They identify the App Registration but can't be used to authenticate
  without the secret.
* The Aras platform license key + activation key — these are tied to the
  hostname/MAC of the install and aren't useful elsewhere.
* The `Aras.ExternalAuthentication` license-filter patcher — this strips a
  feature-license gate. Note that running it without a valid Aras commercial
  agreement may violate your Aras Innovator EULA. Use accordingly.
