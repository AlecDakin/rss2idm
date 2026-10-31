# rss2idm

Show RSS and Atom headlines as a scrolling two-line ticker on an **iDotMatrix 32×32 Bluetooth LED display**.

`rss2idm.sh` is a single Bash script. Each time it runs it picks the next feed in your list, turns the latest headlines into an animated 32×32 GIF, and uploads it to the display. Run it from cron and the display works through your feeds all day.

![Example output, enlarged six times. The real display is 32×32 pixels.](docs/demo.gif)

*Example output, enlarged six times, using placeholder headlines. The real display is 32×32 pixels.*

> This is an unofficial hobby project. It is not affiliated with or endorsed by the makers of iDotMatrix displays.

## What it does

1. Picks the next feed from your list and fetches it. An unreachable or empty feed is skipped.
2. Takes the latest headlines and shares them across two lines of crisp 8×16 pixel text, separated by dim diamonds.
3. Adds the feed's own icon at the front, scaled to fit. If the feed has none, a generic orange "RSS" tile is used instead.
4. Colours the second line using the icon's dominant colour.
5. Ends the two lines with the time and date the feed was published, one directly above the other.
6. Builds an optimised looping GIF and uploads it over Bluetooth.

It is also careful about when it does the work:

- **Skips unchanged feeds.** If the headlines have not changed since the last upload, nothing is rendered or sent.
- **Retries failed uploads.** Bluetooth connections occasionally drop, so each upload is tried up to three times.
- **Runs one at a time.** A lock stops a slow upload from colliding with the next scheduled run.
- **Remembers its place.** Rotation position and the last upload are stored in `~/.local/state/rss2idm/`.

## Requirements

### Hardware

| Item | Notes |
|---|---|
| iDotMatrix **32×32** display | The script produces 32×32 images. Other sizes are not supported. |
| A Linux computer within Bluetooth range | A Raspberry Pi suits leaving it running all day. |
| A Bluetooth **Low Energy** adapter | Built in, or a USB dongle. |

### Software

The script is for **Linux** with the BlueZ Bluetooth stack. It relies on GNU versions of `date` and other core tools, so it will not run unchanged on macOS or BSD.

| Requirement | Used for | Arch package | Debian package |
|---|---|---|---|
| [python3-idotmatrix-client](https://github.com/derkalle4/python3-idotmatrix-client) | Uploading to the display | clone from GitHub | clone from GitHub |
| Bash 4 or later | Running the script | `bash` | `bash` |
| curl | Fetching feeds and icons | `curl` | `curl` |
| xmllint | Reading feed XML | `libxml2` | `libxml2-utils` |
| ImageMagick 6 or 7 | Drawing text and building frames | `imagemagick` | `imagemagick` |
| gifsicle | Optimising the GIF | `gifsicle` | `gifsicle` |
| Python 3 | Decoding HTML entities in headlines | `python` | `python3` |
| fontconfig | Locating the font | `fontconfig` | `fontconfig` |
| [GNU Unifont](https://unifoundry.com/unifont/) | The 8×16 pixel font | `otf-unifont` (AUR) | `fonts-unifont` |
| BlueZ | Bluetooth | `bluez` `bluez-utils` | `bluez` |
| util-linux | `flock` for the run lock | `util-linux` | `util-linux` |

The upload client needs a few extra things of its own: Python 3 with `venv`, Git, and on Debian-based systems the `libopenblas0` package, which its `numpy` dependency expects. The [setup guide](docs/SETUP.md) lists everything for both systems.

Both ImageMagick 6 (Debian 12) and 7 (Arch, Debian 13) work. The script uses `magick` where it exists and falls back to `convert` where it does not.

## Quick start

```bash
# 1. Install the dependencies (see docs/SETUP.md for the full lists)

# 2. Install the upload client in your home folder
cd ~
git clone https://github.com/derkalle4/python3-idotmatrix-client.git
cd python3-idotmatrix-client && ./create_venv.sh
./run_in_venv.sh --scan            # should list your display, named IDM-...

# 3. Get the script and make it executable
git clone https://github.com/YOUR-USERNAME/rss2idm.git
chmod +x rss2idm/rss2idm.sh

# 4. Edit the FEEDS list at the top of the script, then test it
./rss2idm/rss2idm.sh -f
```

The first run takes longest, especially on a small board such as a Raspberry Pi. **The display freezes while a GIF uploads**; this is normal.

Full instructions for Arch and Debian, including Bluetooth set-up and troubleshooting, are in the **[setup guide](docs/SETUP.md)**.

## Usage

| Command | Effect |
|---|---|
| `./rss2idm.sh` | Show the next feed in the list |
| `./rss2idm.sh -f` | Force a rebuild and upload, even if nothing has changed |
| `./rss2idm.sh <feed_url>` | Show just that feed, with no rotation |

### Running it on a schedule

Add this with `crontab -e` to refresh every 15 minutes and keep a log:

```
*/15 * * * * $HOME/rss2idm/rss2idm.sh >> $HOME/rss2idm.log 2>&1
```

Without the `>> ... 2>&1` part, cron discards the script's output and any errors with it.

Please be considerate to the sites whose feeds you use. With six feeds and a run every 15 minutes, each feed is fetched once every 90 minutes, which is gentle. Shorter intervals are best avoided.

## Configuration

Everything is set in the block at the top of the script.

| Setting | Default | Meaning |
|---|---|---|
| `FEEDS` | six example feeds | Feed URLs, shown one per run in this order |
| `MAX_ITEMS` | 6 | Headlines used per feed, shared across the two lines |
| `DELAY` | 8 | Time per frame in hundredths of a second; higher scrolls slower |
| `STEP` | 2 | Pixels moved per frame; lower is smoother but makes a larger file |
| `USE_ICON` | 1 | Set to 0 to leave out the icon |
| `ICON_MAX_WIDTH` | 160 | Widest icon kept, scaled to 32 pixels high |
| `SHOW_CLOCK` | 1 | Set to 0 to leave out the time and date |
| `LINE1_COLOR` | white | Colour of the top line |
| `LINE2_COLOR_DEFAULT` | orange | Bottom line colour when none can be taken from the icon |
| `IDM_DIR` | `~/python3-idotmatrix-client` | Where the upload client is installed |
| `IDM_ADDRESS` | auto | Bluetooth address of the display, if you have more than one |
| `UPLOAD_TRIES`, `RETRY_DELAY` | 3, 5 | Upload attempts, and seconds between them |

To start again from the first feed, delete `~/.local/state/rss2idm/`.

## Limitations

- The display holds **one GIF at a time**, so feeds take turns rather than showing together.
- Bluetooth uploads are slow and freeze the display while they run.
- Headlines are shown as the feed provides them. Long headlines make a long scroll and a larger upload, so `MAX_ITEMS` is kept modest.
- The time shown is the one the feed publishes, converted to the computer's local time zone. If a feed gives no date, the local time is used instead.

## Credits

- [python3-idotmatrix-client](https://github.com/derkalle4/python3-idotmatrix-client) by derkalle4, which does the Bluetooth work. It is licensed under the GNU GPL v3. This project only runs it as a separate program and does not include any of its code.
- [GNU Unifont](https://unifoundry.com/unifont/) for the 8×16 pixel font.
- [ImageMagick](https://imagemagick.org/) and [gifsicle](https://www.lcdf.org/gifsicle/) for the image work.

Headlines and icons belong to their respective publishers.

## Licence

Released under the MIT Licence. See the `LICENSE` file.
