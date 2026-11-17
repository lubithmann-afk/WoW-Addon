# AHWatch
Auction house add-on for Wow forever.

A watch list of up to 20 items checked in one search, two buy keys (Buy instantly grabs whatever is at your price; the big button works item by item), margin mode where your max follows where real supply starts, a Deals list, selling tools (Sell, Quick Sell, Mine), a profit ledger, price history with graphs and tooltips, and price-trend arrows on crafting materials.

New to it? Open **Settings** (bottom right of the AH Watch window) and press **Show me around** for a quick tour, or type `/ahw tour`.

## Install
1. Click **Code → Download ZIP** on this page.
2. Open the zip and copy the **AHWatch** folder into your game's `Interface\AddOns` folder.
3. **Windows, once:** open `Interface\AddOns\AHWatch` and double-click **Turn on auto-update**.

That's it. From then on, every time Windows starts, AHWatch checks this page, installs any newer version, and fixes the game's interface number so it isn't marked "out of date", then closes by itself.

To check right away, double-click **Check for updates now** in the same folder. To stop it, double-click **Turn off auto-update**.

## Releasing a new version
Bump `## Version:` in `AHWatch/AHWatch.toc` and push to `main`. Everyone's copy updates the next time their PC starts (or when they check now).
