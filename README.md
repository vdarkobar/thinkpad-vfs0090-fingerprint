# Lenovo ThinkPad P50 Fingerprint Sensor


A Fedora-focused installer for initializing and enabling the Validity/Synaptics VFS7500 fingerprint reader used in ThinkPad P50-era laptops.
<a href="https://github.com/vdarkobar/fingerprint-reader-firmware">*</a>.</i>


<details>
  <summary>Setup</summary>
  <p>Run on a clean Fedora Workstation with a Validity/Synaptics VFS0090 <code>138a:0090</code> fingerprint reader:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/thinkpad-vfs0090-fingerprint/main/setup.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>

<details>
  <summary>Cleanup</summary>
  <p>Cleanup script for the ThinkPad / Validity VFS0090 <code>138a:0090</code> fingerprint setup created by setup.sh:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/thinkpad-vfs0090-fingerprint/main/cleanup.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
