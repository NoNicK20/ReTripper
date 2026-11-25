# Google Maps setup for ReTripper

ReTripper shows the real Google Maps view inside the app, using Google's official
Maps SDK, Navigation SDK and Places SDK for iOS. It never opens the Google Maps
app, Safari or a web page, and it never swaps in Apple Maps. If no API key is
built into the app, the map area shows **"Google Maps is not configured"**.

You need a Google Cloud project with billing and one API key. **Only you can do
these steps**: they involve your Google account and your payment details.
Nothing below was done for you, and billing has not been turned on.

---

## 1. Create a Google Cloud project

1. Go to <https://console.cloud.google.com/> and sign in.
2. Click the project picker at the top, then **New project**.
3. Name it, for example `ReTripper`, and click **Create**.

## 2. Turn on billing (needs your approval and a payment method)

Google Maps Platform does not work without a billing account, even inside the free
usage allowance.

1. Open **Billing** in the left menu.
2. Link a billing account to the `ReTripper` project, or create one.

## 3. Check pricing and free allowances first

Prices and free monthly allowances change, so read Google's current figures before
you go further:

- Pricing overview: <https://mapsplatform.google.com/pricing/>
- Detailed price list: <https://developers.google.com/maps/billing-and-pricing/pricing>

What ReTripper uses:

| What happens in the app | Google product | How it is billed (check the pages above) |
|---|---|---|
| Showing the map | Maps SDK for iOS (mobile dynamic maps) | Check the current price list |
| Turn-by-turn guidance to a destination | Navigation SDK | Charged per navigation destination/trip |
| Typing in the destination search box | Places API (New): Autocomplete | Charged per request/session |

ReTripper limits search cost by waiting until you pause typing and by routing straight
to the chosen Place ID, so it never makes a separate "Place Details" request.

## 4. Enable the APIs

Go to **APIs & Services → Library** and enable these three:

1. **Maps SDK for iOS**
2. **Navigation SDK** (if you can't enable it, your account may need Google's
   approval. Follow the console's prompt or contact Google Maps Platform sales.)
3. **Places API (New)**
4. **Map Tiles API** — used to draw the map that ReTripper streams to the
   Tripper Dash screen. Billed per tile, so keep the quotas in step 7 tight.

## 5. Create and restrict the API key

1. Open **APIs & Services → Credentials → Create credentials → API key**.
2. Open the new key, then:
   - **Application restrictions:** choose **iOS apps** and add the bundle ID
     `com.nonick20.retripper`.
   - **API restrictions:** choose **Restrict key** and select only
     *Maps SDK for iOS*, *Navigation SDK*, *Places API (New)* and
     *Map Tiles API*.
3. Click **Save** and copy the key.

Important: iOS map keys are built into the app file, so anyone with the app file can
extract the key. The restrictions above, plus the quotas in step 7, are what protect
you. Never paste the key into code, chat, issues or commits.

## 6. Add the key to GitHub Actions

1. Open <https://github.com/NoNicK20/ReTripper> and go to **Settings → Secrets and
   variables → Actions**.
2. Click **New repository secret**.
3. **Name:** `GOOGLE_MAPS_API_KEY`. **Secret:** paste the key. Click **Add secret**.
4. Re-run the latest workflow, or push any commit. The build step writes the key
   into a temporary `Config/Secrets.xcconfig`, which is never committed and is
   deleted afterwards. The build log says only whether a key was embedded.

**Warning about this repository:** the repository is public, so any signed-in GitHub
user can download the build's IPA artifact, and the key is inside it. Before you add
the secret, either make the repository private (**Settings → General → Danger Zone →
Change visibility**) or accept that risk and rely on the restrictions and quotas.

For building on your own Mac instead: copy `Config/Secrets.example.xcconfig` to
`Config/Secrets.xcconfig` and put the key there. Git ignores that file.

## 7. Set quotas and billing alerts

1. **Budget alert:** go to **Billing → Budgets & alerts → Create budget**, choose the
   `ReTripper` project, set a monthly amount, and keep the email alerts at 50%, 90%
   and 100%.
2. **Quotas:** go to **APIs & Services → Enabled APIs**. For each of the three APIs,
   open **Quotas & System Limits** and lower the per-day request limits to what one
   rider needs. Once a limit is reached, that API stops working for the rest of the
   day, so nothing above the limit can be charged.

## 8. Install on your iPhone and check it

The GitHub build makes an **unsigned** IPA. An iPhone only installs apps that are
signed with your Apple developer identity:

1. Download **ReTripper-unsigned-IPA** from the workflow run, or build in Xcode 26 on
   a Mac with your Apple ID selected under **Signing & Capabilities**.
2. The app asks for two Apple capabilities to join the motorcycle's Wi-Fi: **Hotspot
   Configuration** and **Access Wi-Fi Information**. These usually need a paid Apple
   Developer Program membership.
3. On the phone, open **Ride**. Accept Google's navigation terms when asked, and allow
   location access. You should see the Google map with the Google logo at the
   bottom-left.

The setup is complete only when the real Google map appears inside ReTripper on
your iPhone.
