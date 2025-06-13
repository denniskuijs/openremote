---
title: "Analysisdocument"
subtitle: "Updateproces virtuele machines automatiseren"
author: [Dennis Catharina Johannes Kuijs]
date: "20 Maart 2025"
lang: "nl"
toc: true
toc-own-page: true
titlepage: true
titlepage-text-color: "FFFFFF"
titlepage-rule-color: "360049"
titlepage-rule-height: 0
titlepage-background: "config/document_background.pdf"
titlepage-logo: "config/logo.png"
logo-width: 35mm
footer-left: "OpenRemote"
footer-center: "\\theauthor"
code-block-font-size: "\\scriptsize"
...

# 1. Inleiding
Om het probleem goed te begrijpen en te voorkomen dat mogelijk het verkeerde probleem wordt opgelost, wordt er voorafgaand aan de start van het project een probleemanalyse gemaakt.
Op basis van de probleemstelling zijn daarna requirements en user stories opgesteld.

Deze onderdelen zijn in dit document uitgewerkt met behulp van de `SPA-` en `MoSCoW` methoden.

# 2. Probleemanalyse

## 2.1. Wat is het probleem?
OpenRemote, opgericht in 2015, is een organisatie die een Open-Source IoT platform ontwikkelt. 
Het doel van het platform is om de integratie van verschillende communicatieprotocollen en databronnen te vereenvoudigen in één gebruiksvriendelijk systeem.

Het platform maakt integratie mogelijk met verschillende soorten sensoren, databronnen, IoT apparaten, en zorgt ervoor dat deze centraal beheerd kunnen worden via een gebruiksvriendelijk managementportaal. De data van deze bronnen kan vervolgens gevisualiseerd worden en worden ingezet in op maat gemaakte applicaties en (mobiele) apps.
De software is volledig Open-Source, waardoor iedereen deze gratis kan gebruiken of eraan bijdragen. Momenteel wordt OpenRemote toegepast in diverse branches, zoals het beheer en monitoring van energiesystemen, crowd management en wagenparken.

Naast het Open-Source product kunnen bedrijven en (overheids)organisaties ervoor kiezen de software (tegen betaling) te laten beheren en onderhouden door OpenRemote. Deze zogenaamde ‘managed’ service wordt steeds populairder en dat brengt nieuwe uitdagingen met zich mee.
Een van de belangrijkste uitdagingen is het onderhouden van de virtuele machines waarop de software van OpenRemote draait.

Het komt regelmatig voor dat deze machines geüpdatet moeten worden, variërend van updates aan het besturingssysteem tot situaties waarbij meerdere (software)pakketten op de virtuele machine moeten worden bijgewerkt.
In de meeste gevallen kunnen deze updates zonder problemen en met minimale downtime worden uitgevoerd, waarbij de virtuele machine intact blijft. Echter, wanneer er te veel wijzigingen in het AWS `CloudFormation` bestand zijn aangebracht, zal Amazon de virtuele machine opnieuw opbouwen, waardoor alle data verloren gaat.

Omdat het updaten een risicovolle actie is en het vooraf niet te voorspellen is wanneer Amazon voor deze ingrijpende maatregel kiest, wordt het proces voor iedere klant en virtuele machine momenteel handmatig uitgevoerd via het managementportaal van Amazon, in plaats van via de `CLI` of de `CI/CD` workflow. 

Voorafgaand aan het updateproces worden verschillende stappen uitgevoerd, waaronder het maken van een `snapshot` (back-up) van de virtuele machine. Deze extra back-up, naast de automatische dagelijkse back-ups, zorgt ervoor dat de klantdata beschermd blijft en niet verloren gaat. 
Na het updateproces wordt de klantdata vervolgens handmatig op de juiste manier hersteld, zodat de klant de software zonder onderbrekingen kan blijven gebruiken.

Door het handmatig uitvoeren van deze taken is het proces tijdrovend, kwetsbaar en foutgevoelig. Naarmate het aantal klanten voor de ‘managed’ service toeneemt, zal het bijwerken steeds meer tijd vergen van het teamlid dat verantwoordelijk is voor deze taak.

## 2.2. Waarom is het een probleem?
Het onderhouden van de virtuele machines is op dit moment enorm foutgevoelig. Veel stappen in het proces worden handmatig uitgevoerd voor iedere machine, wat het risico op fouten en verstoringen vergroot en de beschikbaarheid van de software negatief kan beïnvloeden.
Naarmate het aantal klanten voor deze ‘managed’ service blijft groeien neemt het onderhoud van al deze virtuele machines steeds meer tijd in beslag van het team. Deze tijd kan beter worden besteed aan het verder ontwikkelen en optimaliseren van het product.

## 2.3. Voor wie is het een probleem? En voor wie niet?
Het probleem doet zich voor bij klanten die ervoor kiezen om de software door OpenRemote te laten beheren en onderhouden. 

Deze bedrijven en/of organisaties betalen een maandelijks bedrag en krijgen in ruil daarvoor toegang tot een virtuele machine waarop de software van OpenRemote draait. De virtuele machine wordt op structurele basis onderhouden door het team van OpenRemote.
Op deze manier hoeven de bedrijven en organisaties die gebruikmaken van deze dienst zich geen zorgen te maken over de technische aspecten van het product (zoals installatie, configuratie en onderhoud) en beschikken zij altijd over een werkende en bijgewerkte versie van de software.

Gebruikers die ervoor kiezen de software zonder tussenkomst van OpenRemote te gebruiken, ondervinden dit probleem niet. Zij zijn zelf verantwoordelijkheid voor de installatie, configuratie en onderhoud van de software op hun eigen infrastructuur en kunnen bij vragen en of problemen terecht op het community forum.

## 2.4. Sinds wanneer is dit probleem ontstaan?
Het probleem is ontstaan vanaf het moment dat de ‘managed‘ service werd aangeboden aan bedrijven en organisaties. Sindsdien is het aantal virtuele machines, die regelmatig onderhoud vereisen, gestaag gegroeid.

## 2.5. Hoe groot is het probleem?
Op dit moment beschouw ik het probleem als redelijk groot. Het aantal klanten dat gebruik wil maken van deze zogenaamde ‘managed‘ service groeit, wat leidt tot een toename van het aantal virtuele machines.

Om het onderhoud van al deze machines te kunnen blijven faciliteren, moet er een oplossing worden gezocht om het updateproces te automatiseren. Deze oplossing moet schaalbaar, veilig en vooral betrouwbaar zijn, zodat de data van klanten tijdens het proces niet verloren gaat of wordt gewijzigd.

## 2.6. Wat gebeurt er op het moment dat het probleem niet wordt opgelost?
Als het probleem niet tijdig wordt opgelost, kan er een situatie ontstaan waarbij nieuwe klanten niet langer gebruik kunnen maken van de ‘managed‘ service dienstverlening.
Dit kan het gevolg zijn van onvoldoende capaciteit binnen het team om al deze ‘virtuele’ machines te blijven onderhouden. Op de lange termijn kan dit leiden tot omzetverlies.

## 2.7. Zijn er nog andere problemen die opgelost/onderzocht moeten worden voordat de gewenste oplossing kan worden bereikt?
De grootste uitdaging is het ontwikkelen van een oplossing waarmee de klantdata automatisch kan worden geback-upt vóór het updateproces en tegelijkertijd ervoor gezorgd wordt dat dit op de juiste manier gebeurt, zonder dat de klantdata verloren gaat of wordt gewijzigd.

Daarnaast moet de oplossing naadloos integreren met de bestaande `CI/CD` workflow, die wordt gebruikt voor het opzetten van de omgevingen van klanten. Het is ook belangrijk om na te denken over de impact op klanten tijdens het updateproces. Klanten moeten op de juiste manier worden geïnformeerd over de voortgang en eventuele gevolgen.

Het oplossen van deze problemen is essentieel voordat het gehele updateproces geautomatiseerd kan worden.

## 2.8. Wat is er in het verleden gedaan om de problemen op te lossen?
Voor zover bekend zijn er geen pogingen gedaan om het probleem op te lossen. De situatie was lange tijd beheersbaar, waardoor er geen directe noodzaak was om het probleem op te lossen.

## 2.9. Welke veranderingsaspecten kunnen de situatie (negatief) beïnvloeden?
Er zijn een aantal valkuilen waarmee rekening gehouden moet worden. Momenteel wordt gebruikgemaakt van het Cloudplatform van Amazon, waarop alle virtuele machines draaien. Daarnaast is de `CI/CD` workflow beschikbaar op `GitHub` Actions.
Een oplossing voor het probleem zal daarom specifiek voor deze platformen worden ontwikkeld en is mogelijk niet zonder aanpassingen te gebruiken op andere platformen of met andere tools.

Als in de toekomt besloten wordt om de dienstverlening uit te breiden naar andere Cloud platformen, zoals Azure of Google, of bijvoorbeeld een andere `CI/CD` provider, kan het nodig zijn om de oplossing aan te passen om operationeel te blijven.
Dit zou kunnen leiden tot een situatie waarin het updateproces voor sommige klanten (tijdelijk) handmatig moet worden uitgevoerd.

## 2.10. Wie profiteert van deze oplossing en wie niet?
De grootste winst wordt behaald voor het team, aangezien zij minder tijd hoeven te besteden aan het onderhouden van de virtuele machines. Deze tijd kan vervolgens worden besteed aan het verder optimaliseren en verbeteren van het product.
Bovendien zorgt het automatiseren van dit proces ervoor dat de infrastructuur en software van klanten sneller kan worden bijgewerkt, waardoor mogelijke problemen en onderbrekingen worden voorkomen.

Gebruikers die de software van OpenRemote zelfstandig gebruiken, profiteren niet van deze oplossing. Zij maken geen gebruik van virtuele machines die worden beheerd door OpenRemote en zijn zelf verantwoordelijk voor de installatie, configuratie en het beheer van de software op hun eigen infrastructuur.
