#!/usr/bin/env bash
# Deploy the phone page, then prove it actually landed.
#
# A silent failure here is invisible and expensive: the Mac gets rebuilt and
# installed, the phone keeps serving whatever it already had, and the two
# disagree in ways that look like transport bugs. It cost several rounds of
# "the phone shows a black screen" before anyone thought to compare them.
#
# Never pipe the deploy into `head`: when head exits it SIGPIPEs vercel, which
# can kill the upload mid-flight. That is exactly how the client ended up a
# version behind the Mac that was talking to it.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> deploying web/"
npx vercel --prod --yes > /tmp/phice-deploy.log 2>&1 || {
  echo "deploy failed:"; tail -20 /tmp/phice-deploy.log; exit 1; }
grep -m1 "Production" /tmp/phice-deploy.log || true

echo "==> verifying the live page matches the repo"
want="$(shasum -a 256 < web/app/app.js | cut -d' ' -f1)"
for attempt in 1 2 3 4 5; do
  got="$(curl -fsS "https://phice.vercel.app/app/app.js?cb=$RANDOM$attempt" \
         | shasum -a 256 | cut -d' ' -f1)" || got=""
  if [ "$got" = "$want" ]; then echo "    app.js matches"; exit 0; fi
  sleep 4
done
echo "the deployed app.js does not match web/app/app.js" >&2
exit 1
