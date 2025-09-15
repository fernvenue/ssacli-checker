# HPE Smart Array Health Checker

[![ssacli-checker](https://img.shields.io/badge/LICENSE-GPLv3%20Liscense-blue?style=flat-square)](./LICENSE)
[![ssacli-checker](https://img.shields.io/badge/GitHub-SSACLI%20Checker-blueviolet?style=flat-square&logo=github)](https://github.com/fernvenue/ssacli-checker)

Daily automatic health check for HPE Smart Array.

## Features

- [x] Automatic daily health check of HPE Smart Array using `ssacli`;
- [x] Systemd service and timer for scheduled updates;
- [x] Optional Telegram notifications with update reports;
- [x] Configurable logging levels;
- [x] Custom Telegram API endpoint support;
- [x] Easy configuration via environment variables.

## Requirements

Before using this script, ensure you have installed `ssacli`, go [HPE Software Delivery Repository](https://downloads.linux.hpe.com/sdr/repo/mcp/pool/non-free/) to get the package.

## Usage

First, download the script to `/usr/local/bin`:

```bash
curl -o /usr/local/bin/ssacli-checker.sh https://raw.githubusercontent.com/fernvenue/ssacli-checker/master/ssacli-checker.sh
```

Give execute permissions:

```bash
chmod +x /usr/local/bin/ssacli-checker.sh
```

Test the script:

```bash
/usr/local/bin/ssacli-checker.sh --help
```

Add systemd service and timer:

```bash
curl -o /etc/systemd/system/ssacli-checker.service https://raw.githubusercontent.com/fernvenue/ssacli-checker/master/ssacli-checker.service
curl -o /etc/systemd/system/ssacli-checker.timer https://raw.githubusercontent.com/fernvenue/ssacli-checker/master/ssacli-checker.timer
```

You can customize the service file to set your environment variables, then enable and start the timer:

```bash
systemctl enable ssacli-checker.timer --now
systemctl status ssacli-checker.timer
systemctl status ssacli-checker.service
```
