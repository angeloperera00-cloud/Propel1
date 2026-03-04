# Propel — README

## About The App

Propel is an accessibility first iOS app built around two main experiences:

1. Scan Space — helps users understand nearby obstacles and distance using the camera and, on supported devices, depth data.
2. Read Label — recognizes and reads text on labels and signs fully on-device.

For the best UX, test Propel on a real iPhone or iPad (not only the simulator). Real-device testing is essential for camera behavior, audio timing, haptics, and VoiceOver interaction.

### Key Apple Frameworks Used

1. SwiftUI — overall app structure and camera screen UI (Scan Space / Read Label).
2. AVFoundation — live camera capture and real-time frame pipeline.
3. Vision — on-device text recognition for Read Label and visual fallback logic.
4. LiDAR / Depth (AVDepthData) — on supported devices, depth data improves obstacle distance estimation in Scan Space.
5. Core Haptics — tactile feedback patterns (clear / caution / stop), with UIKit haptics fallback when needed.
6. AVSpeechSynthesizer (AVFoundation) — reliable on-device speech output for reading labels and safety cues.
7. App Intents (Siri Shortcuts) — quick voice commands (optional in Playgrounds, fully supported in Xcode).

### Tutorials / References Used

1. Apple Developer Documentation (Vision, AVFoundation, Core Haptics, App Intents)
2. WWDC sessions and sample code focused on accessibility, Vision text recognition, and camera capture best practices
3. Accessibility guidance inspired by Apple Human Interface Guidelines (clear feedback, simple interactions, VoiceOver-friendly structure)

### Testing Device

Tested primarily on real devices:
iPad Pro, iPhone Pro, or iPhone Pro Max.

## A Story

I had many app ideas, but none of them felt meaningful. I didn’t want to build something just to submit a project I wanted to build something that could truly help someone.

One day, while I was in Naples,Italy I met a blind woman inside a supermarket. She was alone and trying to find a few products, but there was no one nearby to assist her. The situation became even more difficult because, inside that space, the network signal was weak and unreliable. In places like supermarkets, basements, or large buildings, internet access can easily become limited, and that made me realize how important offline support can be.

She asked me if I could help her find the products she needed, so I stayed with her and tried to help. What seemed like a simple task to me was actually a frustrating and time-consuming experience for her. Many bottles and packages had similar shapes, and without being able to clearly identify labels, it was difficult to know what was what. That moment stayed with me.

As I learned more, I also understood that mobility challenges go beyond what is on the ground. A white cane is essential, but it mainly helps detect what is directly on the floor. Obstacles placed higher up—such as signs, shelves, edges, or objects at chest or head height—can still become dangerous and cause collisions or injuries. That made me think not only about product recognition, but also about safer movement in everyday spaces.

After that experience, I had the opportunity to speak with her more, and later I connected with members of the local blind community in Naples, including people from CIVES. Listening to their experiences helped me understand accessibility in a deeper way. They shared practical, everyday challenges: moving through unfamiliar places, shopping independently, reading product information, and completing simple tasks that many people take for granted.

Those conversations changed the way I looked at building apps. I realized accessibility is not only about adding a feature—it is about designing with empathy from the very beginning. Over time, I started using my own phone as if I were blind, relying only on VoiceOver, so I could better understand the importance of clear structure, predictable interactions, and strong feedback.

While building Propel, I went through multiple design iterations. At first, I focused on what looked visually nice, but the community taught me something more important: simplicity matters more than beauty. Many blind users rely on predictable touch areas, clear audio guidance, and fast feedback. So I redesigned the app around accessibility-first principles—large touch zones, minimal interface, strong VoiceOver support, offline reliability, and clear feedback through sound and haptics.

When I shared early versions of the app with members of the community, their reactions motivated me even more. Seeing them smile while testing something I had built made me realize that technology can be more than just code—it can support dignity, independence, and confidence.

Propel was born from those experiences. My vision is to continue improving it with privacy-respecting, on-device intelligence and offline-first design, so blind and low-vision users can navigate spaces more safely and identify products more independently, without having to rely on constant assistance from others.

This is the project I want to bring to the Swift Student Challenge—a story rooted in listening first, then building something meaningful.

---

## The Next Steps (Roadmap)

In the near future, I plan to improve Propel in ways that make it more reliable, faster, and even more accessible:

1. Read Label improvements  
   1) Add an OCR lock or pause after a good read to avoid constant re-reading  
 
2. Scan Space upgrades  
   1) More consistent distance and hazard feedback using sound and haptic patterns  
   2) Better calibration and smoothing to reduce false positives and improve confidence

3. Accessibility-first refinements  
   1) Even larger touch zones and more predictable corner interactions  
   2) Cleaner VoiceOver focus order and fewer steps to start scanning

4. Offline-first growth  
   1) Expand on-device recognition and structured outputs for common product labels  
   2) Continue optimizing performance for real-world usage on device

5. Real-user feedback loop  
   1) Keep testing with members of the blind community (CIVES) and iterate based on what they actually need
