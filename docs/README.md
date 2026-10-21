# Signage Studio

Produktens målbild och luckor mot en mogen skyltplattform finns i [SCREENCLOUD_PARITY.md](SCREENCLOUD_PARITY.md). Signage Studio bygger egen kod och egen design, med målet att täcka motsvarande arbetsflöden.

En liten, egen digital-signage-lösning för Philips Android TV. TV:n kör en native Android-app i helskärm; den använder inte TV:ns webbläsare. Adminvyn används från dator/mobil och publiceras som statiska filer från GitHub Pages. Spellistor och publicerat innehåll sparas i Supabase. GitHub innehåller applikationskoden, inte publicerade videor eller meddelanden.

## Innehåll som går att visa

- Textmeddelanden med rubrik, brödtext, visningstid, engångsdatum och återkommande veckodagar/klockslag.
- Klocka och datum med valfri rubrik/underrad.
- Videor från uppladdad MP4 eller direkt MP4-länk. Appen hämtar videon till TV:ns lagring och spelar den lokalt.
- En enkel JSON-feed. Spelaren läser fälten `message`, `value`, `subtitle`, `text`, `status` och `updated_at` ur ett JSON-objekt. Senaste lyckade feed-svaret sparas för offlinevisning.
- Webbsidor och live-dashboards som visas i den inbyggda spelaren.

Adminvyn kan organisera skärmar i grupper efter plats eller team, filtrera på grupp/status/innehåll, flytta flera skärmar samtidigt och köa fjärråtgärder i bulk. Gruppborttagning avregistrerar inte skärmar; de blir bara ogrupperade.

Spelaren hämtar spellistan och rapporterar sin status var 15:e sekund. Var femte minut rapporterar den även appversion, TV-modell, Android-version, skärmupplösning och nätverkstyp till skärmens diagnostikpanel. Adminvyn visar vilka skärmar som är online, vad de visar och en faktisk livebild från TV:n som uppdateras var 30:e sekund. Skärmbilder lagras privat och kan bara visas av teammedlemmar med åtkomst till skärmen. Välj **Visa nu** på en post för att visa den direkt på en skärm; **Återgå till spellistan** startar rotationen igen. Video och senaste spellista sparas lokalt, så en nätverksstörning inte stoppar befintligt innehåll. HLS-länkar fungerar som ström när nät finns, men för offlinevisning bör videon vara en direkt MP4.

## Publicera adminvyn på GitHub Pages

1. Skapa ett Supabase-projekt och skapa det första Auth-kontot som ska vara administratör. Kör därefter `supabase/schema.sql` i SQL Editor. För en befintlig installation kör du migrationsfilerna i ordning: `20261020_live_screen_control.sql`, `20261020_reusable_playlists.sql`, `20261020_recurring_schedule.sql`, `20261020_team_permissions.sql`, `20261020_remote_content_control.sql`, `20261020_channels.sql`, `20261020_screen_layouts.sql`, `20261021_player_commands.sql`, `20261021_temporary_screen_casts.sql`, `20261021_media_library.sql`, `20261021_channel_playlists.sql`, `20261022_multi_zone_playlists.sql`, `20261023_screen_pairing_recovery.sql`, `20261024_screen_operating_hours.sql`, `20261025_synchronized_playback.sql`, `20261026_player_autostart.sql`, `20261027_screen_groups.sql`, `20261028_group_viewer_access.sql`, `20261029_live_feed_refresh.sql`, `20261030_activity_audit_log.sql`, `20261031_private_live_previews.sql`, `20261101_playback_history.sql`, `20261102_player_device_diagnostics.sql`, `20261103_live_integration_health.sql` och `20261104_secure_live_integrations.sql`, `20261106_screen_health_history.sql`, `20261107_playlist_reordering.sql`, `20261110_remote_preview_refresh.sql`, `20261112_media_expiration.sql`, `20261113_screen_identity.sql` och `20261114_player_identity.sql` och `20261115_screen_publication.sql`, `20261116_screen_preview_restore.sql` och `20261117_publication_approval.sql` och `20261118_locations.sql`. Mediebiblioteket sparar återanvändbart innehåll med sökbara taggar och valfri utgångstid; utgången tid synkas till alla spellistreferenser och kontrolleras även från TV:ns offlinecache och låter redaktörer lägga till poster i valfria spellistor; ändringar av en bibliotekspost slår igenom i alla spellistor som använder den. Spellistemigrationen bevarar befintligt innehåll, schemaläggningsmigrationen lägger till veckoscheman och team-migrationen inför rollerna admin, editor och viewer samt ger befintliga Auth-konton adminrollen. Remote-control-migrationen låter redaktörer välja innehåll som ska visas direkt utan att ge generell skärmhantering. Kanaler innehåller flera återanvändbara spellistor med egna scheman, prioritet och ordning. Veckokalendern markerar överlappande kanaler per skärm och visar vilken prioritet som vinner; vid samma prioritet varnar den att båda kan visas. Layouter kan visa ticker eller sidopanel samtidigt med huvudinnehållet. Omparkoppling skapar en ny kod på befintlig skärmprofil, så innehåll och inställningar behålls. Databasen tillåter nu bara ett aktivt skärmnamn en gång, och Android-spelaren kopplar dessutom en pseudonymiserad enhetsidentitet till TV-profilen så nya parkopplingskoder på samma TV återanvänder profilen. Skärminnehåll sparas som utkast och når inte spelaren förrän en redaktör publicerar det från skärmkortet; publicering skapar en versionshistorik, köar synk och spelaren behåller senaste publicerade version för offlinevisning. Skärminnehåll sparas som utkast och når inte spelaren förrän en redaktör publicerar det från skärmkortet; publicering skapar en versionshistorik, köar synk och spelaren behåller senast publicerad version för offlinevisning. Förhandsvisa utkast från skärmkortet och bläddra i publicerade versioner; återställning skapar en ny publicerad version och köar synk utan att skriva över redigerbara utkast. Redaktörer kan skicka en fryst utkastversion till admin för godkännande; godkännande publicerar just den inskickade versionen och avslag kan innehålla en kommentar. Skärmens öppettider, synkad uppspelning, autostart, fjärrsynk, fjärrbegärd livebild, fjärromstart och tidsbegränsade utskick hanteras från adminvyn. Skärmgrupper används för filter och massflytt; Gruppmedlem kan begränsas till uttryckligen tilldelade grupper. Aktivitetsloggen registrerar ändringar utan att logga innehållsvärden. Uppspelningshistoriken registrerar övergångar som spelaren rapporterar och kan filtreras och exporteras som CSV. Integrationsvyn visar feedstatus per skärm. Pulse-hemligheter lagras i en separat skyddad tabell och lämnas bara till en aktiv spelare när den begär en feed som hör till sin tilldelade skärm; token ligger inte i media- eller slide-URL:er. Driftvarningar i skärmvyn samlar aktiva skärmar som tappat kontakt, misslyckade eller fastnade fjärrkommandon samt färska feedfel; åtgärdsknappar öppnar rätt skärm eller feedfilter. Skärmhälsa registrerar online-/offlineövergångar automatiskt varje minut i Supabase; adminvyn visar senaste händelser och senaste heartbeat per skärm. Händelsetiden är när systemet upptäckte tillståndet, inte en exakt mätning av när nätverksavbrottet började.

Distribuera Edge Functions `report-screen-preview` och `invite-team-member` med `supabase functions deploy report-screen-preview --project-ref <project-ref>` respektive `supabase functions deploy invite-team-member --project-ref <project-ref>`. Båda använder servernyckeln endast på serversidan; den läggs aldrig i adminvyn eller TV-appen.
2. I Supabase Auth: stäng av publik registrering och bjud in ytterligare admin-konton. Schemat ger befintliga Auth-konton adminrollen. Lägg till GitHub Pages-adressen under **URL Configuration → Redirect URLs** när den är känd.
3. `admin/config.js` är redan konfigurerad med projektets Project URL och anon/public key. Anon-nyckeln är avsedd att finnas i klientkod; **service-role/secret-nyckeln får aldrig läggas i appen, GitHub Pages eller Android-bygget**. Åtkomst ska begränsas med RLS-policys.
4. Skapa ett GitHub-repo och lägg upp innehållet i den här mappen på branchen `main`. Ett publikt repo passar GitHub Pages kostnadsfria flöde; det innehåller bara källkod och den avsedda publika Supabase anon-nyckeln.
5. I repo-inställningarna, välj **Settings → Pages → Build and deployment → Deploy from a branch**, sedan `main` och `/docs`. `docs/` innehåller adminvyn för GitHub Pages. Det finns också en Actions-workflow för automatisk publicering om kontot kan köra GitHub Actions.
6. Lägg till repo-variablerna `SUPABASE_URL` och `SUPABASE_ANON_KEY` under **Settings → Secrets and variables → Actions → Variables**. Använd projektets anon/public key; de används när Android-appen byggs i GitHub Actions. Det är en publik klientnyckel och den skyddar inte data på egen hand.

När Pages-workflowen är klar finns adminvyn på `https://<github-användare>.github.io/<repo>/`. Logga in med ett inbjudet admin-konto, skapa en skärm och använd den sex tecken långa parkopplingskoden i TV-appen. Koden går bara att använda en gång.

## Bygg och installera TV-appen

1. Hämta [Signage Player 1.17.0 APK:n](https://sherryberry001.github.io/signage-studio/signage-player-v1.17.0.apk) från GitHub Pages. APK:n byggs lokalt och följer med repots publicerade `/docs`-filer. Spelaren binder en hashad Android-enhetsidentitet till profilen, så nya parkopplingskoder på samma TV återanvänder den och tomma dubblettprofiler stängs av. Alternativt kör **Actions → Build Android TV player** eller bygg lokalt från `player-android/` med Android SDK 35 och JDK 17.
2. På Philips-TV:n behöver appen installeras en gång. Google Play kräver Google-inloggning; om du inte vill logga in kan APK:n sideloadas. För installation över Wi-Fi: slå på **Trådlös felsökning** under TV:ns utvecklaralternativ, välj **Parkoppla enheten med parkopplingskod** och kör `adb pair TV-IP:PARKOPPLINGSPORT` på datorn. Ange koden som visas på TV:n. Kör sedan `adb connect TV-IP:ANSLUTNINGSPORT` med IP och port från huvudvyn för Trådlös felsökning och installera med `adb install -r signage-player-v1.17.0.apk`. Parkopplingsporten och anslutningsporten kan vara olika. **USB-felsökning kräver en USB-kabel** och gör inte TV:n synlig via Wi-Fi. Alternativt kan APK:n kopieras till TV:n via USB och öppnas med en filhanterare.
3. Starta **Signage Player**, skriv parkopplingskoden från adminvyn och låt appen gå i helskärm.

Om TV:n inte startar appen automatiskt efter omstart behöver den ställas in som startapp på TV:n, om firmware tillåter det. Den här första versionen installerar inte enhetsägar-/kiosk-läge och kringgår inte Androids installationsbekräftelser.

## Teamroller

- **Admin:** hanterar skärmar, innehåll, spellistor och teamroller.
- **Redaktör:** hanterar innehåll och spellistor, men inte skärmtilldelning eller teamroller.
- **Läsbehörig:** kan se alla skärmar och allt innehåll men inte ändra dem.
- **Gruppmedlem:** kan bara se skärmar och innehåll för de grupper en admin tilldelar.

Admin kan bjuda in via Team-vyn och tilldela rollen i samma steg. Edge Function verifierar adminrollen, skickar inbjudan och lägger till Auth-kontot i teamet; redan befintliga Auth-konton läggs till utan en extra inbjudan. Service-rollsnyckeln finns bara på serversidan. Rollkontrollerna skyddas av Supabase RLS och RPC:er; inloggning ensam ger inte åtkomst.

## Lägga till innehåll

- **Spellistor:** skapa en spellista och tilldela den till flera skärmar. I Innehåll kan du centralt byta namn, dra objekt för att sortera dem, använda upp-/nedknappar med tangentbordet, ta bort objekt och se vilka skärmar och kanaler som använder listan. Ordningsbytet sparas atomärt och synkas till alla anslutna skärmar.
- **Skärmlayouter:** välj helskärm, huvudyta med ticker eller huvudyta med sidopanel. Texten eller en separat spellista i den andra zonen kan uppdateras centralt och synkas till TV:n.
- **Kanaler:** bygg en kanal av flera återanvändbara spellistor. Varje spellista kan ha egen ordning, prioritet, datumintervall, veckodagar och dagligt tidsfönster; schemalägg sedan kanalen på en eller flera skärmar. Veckovyn visar kanalernas tider per skärm med veckonavigering och skärmfilter. TV:n väljer aktiv kanal och spellista lokalt från synkat innehåll, även när nätet är nere; utan aktiv kanal används skärmens grundspellista.
- **Fjärråtgärder:** köa omedelbar synk eller omstart för en specifik spelare. Offline-spelare hämtar kommandot när de återansluter, och kommandot kvitteras i en historiktabell. Ladda ned ett JSON-felsökningspaket med enhetsdiagnostik, uppkopplingshändelser, feedstatus och kommandon; innehållstext, parkopplingskoder och URL-hemligheter ingår inte.
- **Textmeddelande:** skriv rubrik/text, välj sekunder och ange valfritt datumintervall, veckodagar och dagliga klockslag. Veckodagar och tider följer TV:ns lokala tidszon; ett klockslag som går över midnatt räknas till dagen då visningsfönstret startar.
- **Video:** ange en direktlänk eller ladda upp en MP4. Uppladdade videor ligger i en publik bucket eftersom TV:n ska kunna spela dem utan användarinloggning. Publicera därför bara innehåll som får visas offentligt.
- **JSON-feed och integrationer:** länken ska returnera JSON. Enkla svar med `message` visas som text; svar med `metrics` eller `items` kan visas som ett native dashboard på TV:n. Feeden hämtas utan HTTP-cache och senaste giltiga svaret sparas för offlinevisning. Ange ett separat uppdateringsintervall på 10–3600 sekunder; spelaren hämtar ny data medan feeden visas, oberoende av spellistans rotationstid. En admin kan skapa en återanvändbar Pulse-anslutning från Integrationer. Display-token sparas separat i Supabase och returneras bara till en aktiverad skärm som använder feeden; ange den aldrig i feed-URL:en.
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


## Platser och avgränsad skärmåtkomst

Administratörer kan skapa platser, flytta skärmar mellan dem och ge gruppmedlemmar läsåtkomst till en hel plats. Platsåtkomsten omfattar skärmar, deras publicerade innehåll, spellistor, kanaler och historik via Supabase RLS. Befintliga gruppbehörigheter fortsätter att fungera och utökas inte automatiskt.
