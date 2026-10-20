# Signage Studio

En liten, egen digital-signage-lösning för Philips Android TV. TV:n kör en native Android-app i helskärm; den använder inte TV:ns webbläsare. Adminvyn används från dator/mobil och publiceras som statiska filer från GitHub Pages. Spellistor och publicerat innehåll sparas i Supabase. GitHub innehåller applikationskoden, inte publicerade videor eller meddelanden.

## Innehåll som går att visa

- Textmeddelanden med rubrik, brödtext, visningstid, engångsdatum och återkommande veckodagar/klockslag.
- Klocka och datum med valfri rubrik/underrad.
- Videor från uppladdad MP4 eller direkt MP4-länk. Appen hämtar videon till TV:ns lagring och spelar den lokalt.
- En enkel JSON-feed. Spelaren läser fälten `message`, `value`, `subtitle`, `text`, `status` och `updated_at` ur ett JSON-objekt. Senaste lyckade feed-svaret sparas för offlinevisning.
- Webbsidor och live-dashboards som visas i den inbyggda spelaren.

Spelaren hämtar spellistan och rapporterar sin status var 15:e sekund. Adminvyn visar vilka skärmar som är online, vad de visar och en liveförhandsvisning när innehållet tillåter det. Välj **Visa nu** på en post för att visa den direkt på en skärm; **Återgå till spellistan** startar rotationen igen. Video och senaste spellista sparas lokalt, så en nätverksstörning inte stoppar befintligt innehåll. HLS-länkar fungerar som ström när nät finns, men för offlinevisning bör videon vara en direkt MP4.

## Publicera adminvyn på GitHub Pages

1. Skapa ett Supabase-projekt och skapa det första Auth-kontot som ska vara administratör. Kör därefter `supabase/schema.sql` i SQL Editor. För en befintlig installation kör du migrationsfilerna i ordning: `20261020_live_screen_control.sql`, `20261020_reusable_playlists.sql`, `20261020_recurring_schedule.sql` därefter `20261020_team_permissions.sql`, `20261020_remote_content_control.sql` `20261020_channels.sql` och slutligen `20261020_screen_layouts.sql`. Spellistemigrationen bevarar befintligt innehåll, schemaläggningsmigrationen lägger till veckoscheman och team-migrationen inför rollerna admin, editor och viewer samt ger befintliga Auth-konton adminrollen. Remote-control-migrationen låter redaktörer välja innehåll som ska visas direkt utan att ge generell skärmhantering. Kanalmigrationen lägger till namngivna kanaler, återkommande kanalvisning per skärm och offlineval i spelaren. Layoutmigrationen lägger till en ticker eller sidopanel som visas samtidigt med huvudinnehållet.
2. I Supabase Auth: stäng av publik registrering och bjud in ytterligare admin-konton. Schemat ger befintliga Auth-konton adminrollen. Lägg till GitHub Pages-adressen under **URL Configuration → Redirect URLs** när den är känd.
3. `admin/config.js` är redan konfigurerad med projektets Project URL och anon/public key. Anon-nyckeln är avsedd att finnas i klientkod; **service-role/secret-nyckeln får aldrig läggas i appen, GitHub Pages eller Android-bygget**. Åtkomst ska begränsas med RLS-policys.
4. Skapa ett GitHub-repo och lägg upp innehållet i den här mappen på branchen `main`. Ett publikt repo passar GitHub Pages kostnadsfria flöde; det innehåller bara källkod och den avsedda publika Supabase anon-nyckeln.
5. I repo-inställningarna, välj **Settings → Pages → Build and deployment → Deploy from a branch**, sedan `main` och `/docs`. `docs/` innehåller adminvyn för GitHub Pages. Det finns också en Actions-workflow för automatisk publicering om kontot kan köra GitHub Actions.
6. Lägg till repo-variablerna `SUPABASE_URL` och `SUPABASE_ANON_KEY` under **Settings → Secrets and variables → Actions → Variables**. Använd projektets anon/public key; de används när Android-appen byggs i GitHub Actions. Det är en publik klientnyckel och den skyddar inte data på egen hand.

När Pages-workflowen är klar finns adminvyn på `https://<github-användare>.github.io/<repo>/`. Logga in med ett inbjudet admin-konto, skapa en skärm och använd den sex tecken långa parkopplingskoden i TV-appen. Koden går bara att använda en gång.

## Bygg och installera TV-appen

1. Hämta [senaste Signage Player APK:n](https://sherryberry001.github.io/signage-studio/signage-player-debug.apk) från GitHub Pages. APK:n byggs lokalt och följer med repots publicerade `/docs`-filer. Alternativt kör **Actions → Build Android TV player** eller bygg lokalt från `player-android/` med Android SDK 35 och JDK 25.
2. På Philips-TV:n behöver appen installeras en gång. Google Play kräver Google-inloggning; om du inte vill logga in kan APK:n sideloadas. Aktivera då utvecklaralternativ och USB-/nätverksfelsökning på TV:n och installera med Android Debug Bridge, eller kopiera APK:n via USB med en filhanterare.
3. Starta **Signage Player**, skriv parkopplingskoden från adminvyn och låt appen gå i helskärm.

Om TV:n inte startar appen automatiskt efter omstart behöver den ställas in som startapp på TV:n, om firmware tillåter det. Den här första versionen installerar inte enhetsägar-/kiosk-läge och kringgår inte Androids installationsbekräftelser.

## Teamroller

- **Admin:** hanterar skärmar, innehåll, spellistor och teamroller.
- **Redaktör:** hanterar innehåll och spellistor, men inte skärmtilldelning eller teamroller.
- **Läsbehörig:** kan se skärmar och innehåll men inte ändra dem.

Bjud först in personen via Supabase Auth. Administratören kan därefter tilldela rollen i Signage Studio. Rollkontrollerna skyddas av Supabase RLS och RPC:er; inloggning ensam ger inte åtkomst.

## Lägga till innehåll

- **Spellistor:** skapa en spellista och tilldela den till flera skärmar. Innehåll och ordning delas mellan alla skärmar som använder den. Skärmar kan även fortsätta med en egen spellista.
- **Skärmlayouter:** välj helskärm, huvudyta med ticker eller huvudyta med sidopanel. Texten i den andra zonen kan uppdateras centralt och synkas till TV:n.
- **Kanaler:** bygg en kanal av en återanvändbar spellista och tilldela den till skärmar med prioritet, datumintervall, veckodagar och dagligt tidsfönster. TV:n väljer den aktiva kanalen lokalt från synkat innehåll, även när nätet är nere; utan aktiv kanal används skärmens grundspellista.
- **Textmeddelande:** skriv rubrik/text, välj sekunder och ange valfritt datumintervall, veckodagar och dagliga klockslag. Veckodagar och tider följer TV:ns lokala tidszon; ett klockslag som går över midnatt räknas till dagen då visningsfönstret startar.
- **Video:** ange en direktlänk eller ladda upp en MP4. Uppladdade videor ligger i en publik bucket eftersom TV:n ska kunna spela dem utan användarinloggning. Publicera därför bara innehåll som får visas offentligt.
- **JSON-feed:** länken ska returnera ett JSON-objekt, till exempel `{"message":"Besöksmottagningen flyttar till entré B"}`.
- **Klocka & datum:** visas enligt TV:ns lokala tid.

TV:n läser senaste spellistan från backend och använder lokala kopior för offlinevisning. För att byta vilken skärm TV:n visar, ta bort appens data eller koppla bort skärmen i adminvyn och aktivera den på nytt.

## Kostnad och begränsningar

Källkoden och GitHub Pages kan användas utan separat webbserver. Supabase har en gratisnivå med begränsad databas-, lagrings- och trafikmängd. Supabase anger att gratisprojekt pausas efter en veckas inaktivitet; en skyltspelare som synkar regelbundet bör normalt hålla projektet aktivt. Se aktuell [Supabase-prissättning](https://supabase.com/pricing) och villkor innan kommersiell eller större användning. Medieutrymme och videoutflöde är den mest sannolika framtida kostnaden.

## Struktur

```text
admin/                 Adminvy för GitHub Pages
player-android/        Native Android TV-spelare
supabase/schema.sql    Databastabeller, RLS och TV-RPC:er
.github/workflows/     Pages-publicering och APK-bygge
```
