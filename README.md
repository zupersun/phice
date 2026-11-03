<div align="center">

![](docs/logo.svg)

# Phice

**Turn an iPhone into a MacBook-style trackpad**

In development · not released yet

</div>

---

A native iPhone app recognises the gestures and talks peer-to-peer to a tiny
agent on the Mac, which applies Apple's own pointer curves and posts the
events. No server between them. Every setting lives on the phone; the Mac agent
is meant to be forgotten.

## Building from source

```bash
swift test                     # the suite
cd Apps && xcodegen generate   # then build the PhiceMac and PhiceiOS schemes
```

<div align="center">

MIT · © 2026 Jasper Sun

</div>
