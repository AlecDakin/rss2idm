# rss2idm: Installation and Use on Arch and Debian

`rss2idm.sh` fetches headlines from RSS or Atom feeds, renders them as a two-line scrolling 32×32 GIF, and uploads it to an iDotMatrix display over Bluetooth.

Each run shows **one feed**, then moves on to the next in the list. Run it on a schedule and the display works through your feeds in turn.

## What it does

- Two lines of 8×16 bitmap text (GNU Unifont), separated by dim diamonds.
- The feed's own icon at the front (or a generic orange "RSS" tile if it has none).
- The feed's publish time (24-hour) and date at the end of the two lines.
- Skips the upload if the headlines have not changed since last time.
- Retries failed Bluetooth uploads, and will not run twice at once.

## 1. Install the dependencies

Debian derivatives such as Ubuntu and Raspberry Pi OS follow the Debian steps.

### Arch Linux (and EndeavourOS, Manjaro)

```bash
sudo pacman -S --needed curl libxml2 imagemagick gifsicle python git fontconfig bluez bluez-utils
yay -S otf-unifont          # AUR; ttf-unifont also works
fc-cache -f
```

### Debian

```bash
sudo apt update
sudo apt install curl libxml2-utils imagemagick gifsicle python3 python3-venv git \
                 fontconfig fonts-unifont bluez libopenblas0
fc-cache -f
```

### Check the font

```bash
fc-match Unifont
```

The output should name a file containing "unifont". If it does not, the script will stop with a message saying so.

### A note on ImageMagick versions

| System | ImageMagick | Command |
|---|---|---|
| Arch (current) | 7 | `magick` |
| Debian 13 (trixie) | 7 | `magick` |
| Debian 12 (bookworm) | 6.9 | `convert` only |

The script detects this itself. If there is no `magick`, it falls back to `convert`, so no change is needed on either system.

## 2. Bluetooth

Make sure the Bluetooth service is running:

```bash
sudo systemctl enable --now bluetooth
```

This works the same on both systems. A built-in adapter or a USB Bluetooth dongle will do, provided it supports Bluetooth Low Energy.

To make sure the adapter is switched on after every reboot, set `AutoEnable=true` in `/etc/bluetooth/main.conf` and restart the service:

```bash
sudo sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
```

## 3. Install the iDotMatrix client

The script uploads through [python3-idotmatrix-client](https://github.com/derkalle4/python3-idotmatrix-client). Install it in your home folder, which is where the script expects to find it:

```bash
cd ~
git clone https://github.com/derkalle4/python3-idotmatrix-client.git
cd python3-idotmatrix-client
./create_venv.sh
```

Find your display, with it switched on and close by:

```bash
./run_in_venv.sh --scan
```

It will list a device named like `IDM-...` with its address. The script defaults to `--address auto`, which uses the first display it finds, so you only need the address if you have more than one.

## 4. Install the script

```bash
cp rss2idm.sh ~/rss2idm.sh
chmod +x ~/rss2idm.sh
```

Open it and edit the settings at the top, mainly the feed list:

```bash
FEEDS=(
    "https://feeds.bbci.co.uk/news/rss.xml"
    "https://www.theverge.com/rss/index.xml"
    # one feed per line, shown in this order
)
```

## 5. First run

Run it by hand, forcing an upload:

```bash
~/rss2idm.sh -f
```

You should see the feed chosen, the headlines, the icon, the frame count, and finally the upload. **The display freezes while the GIF uploads**, which can take a little while. This is normal.

## 6. Everyday use

| Command | Effect |
|---|---|
| `./rss2idm.sh` | Show the next feed in the list |
| `./rss2idm.sh -f` | Force a rebuild and upload, even if nothing has changed |
| `./rss2idm.sh <feed_url>` | Show just that feed, with no rotation |

If a feed is unreachable or has no headlines, it is skipped in favour of the next one.

## 7. Run it on a schedule

Edit your crontab with `crontab -e` and add, for example:

```
*/30 * * * * $HOME/rss2idm.sh >> $HOME/rss2idm.log 2>&1
```

That changes the display every 30 minutes and keeps a log you can read if it stops updating. Because each run advances one feed, six feeds at 30-minute intervals gives a full rotation every three hours.

## 8. Settings worth knowing

| Setting | Default | Meaning |
|---|---|---|
| `MAX_ITEMS` | 6 | Headlines per feed, shared across the two lines |
| `DELAY` | 8 | Time per frame in hundredths of a second; higher is slower |
| `STEP` | 2 | Pixels moved per frame; lower is smoother but makes a larger file |
| `ICON_MAX_WIDTH` | 160 | Widest icon kept, scaled to 32 pixels high |
| `USE_ICON` | 1 | 0 removes the icon altogether |
| `SHOW_CLOCK` | 1 | 0 removes the time and date |
| `LINE1_COLOR` | white | Colour of the top line |
| `LINE2_COLOR_DEFAULT` | orange | Bottom line colour when none can be taken from the icon |
| `IDM_ADDRESS` | auto | Bluetooth address of the display |
| `UPLOAD_TRIES` / `RETRY_DELAY` | 3 / 5 | Upload attempts, and seconds between them |

The output GIF is saved as `~/rss_scroll.gif`. The rotation position and last-upload record live in `~/.local/state/rss2idm/`; delete that folder to start again from the first feed.

## 9. Troubleshooting

**"Unifont not found".** Install the font as in step 1, then run `fc-cache -f`.

**`ImportError: libopenblas.so.0` when running the client.** The client's `numpy` library needs the OpenBLAS system library, which is missing on a minimal Debian or Raspberry Pi OS install. Install it, then run the client again; there is no need to rebuild the virtual environment:

```bash
sudo apt install libopenblas0
./run_in_venv.sh --scan
```

**`No powered Bluetooth adapters found` (POWERED_OFF).** The system can see an adapter, but it is switched off or blocked. Check, and switch it on:

```bash
rfkill list bluetooth              # "Soft blocked: yes" means it is blocked
sudo rfkill unblock bluetooth
sudo systemctl enable --now bluetooth
bluetoothctl power on
bluetoothctl show | grep Powered   # should say "Powered: yes"
```

If `bluetoothctl list` shows no controller at all, the adapter is not being detected. Check `lsusb` and `dmesg | grep -i bluetooth` for firmware errors; many USB dongles use Realtek chips, which need `sudo apt install firmware-realtek` on Debian.

**The upload fails or times out.** Check that the display is on and close by, then try the client's reset: `./run_in_venv.sh --address auto --reset`. The script already retries three times.

**The display cannot be found.** Confirm Bluetooth is on (`systemctl status bluetooth`), unplug and replug the display, and run `--scan` again.

**Strange characters in headlines.** The script decodes the usual HTML entities. If a feed still shows odd symbols, run it by hand with that feed's address and send the output on.

**Nothing changes on the display.** The script skips the upload when the headlines and feed date are unchanged. Use `-f` to force it.

**It works by hand but not from cron.** Read `~/rss2idm.log`. Cron runs with a minimal environment, so the log usually shows what is missing.
