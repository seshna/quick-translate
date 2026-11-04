import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: test
  property int stage: 0
  property bool changedSetting: false
  property bool sawSinglePreview: false
  property bool restored: false
  property bool queuedSettingOnFailure: false
  function check(value, message) {
    if (!value) { console.error("FAIL: " + message); Qt.quit() }
    return value
  }
  Plugin.QuickTranslate { id: target }
  Timer {
    interval: 20
    repeat: true
    running: true
    onTriggered: {
      if (target.translating && target.translationReviewEnabled) {
        if (!test.check(target.testOutput.indexOf("PRIVATE DRAFT") < 0 && target.testOutput.indexOf("FINAL REVIEW") < 0,
                        "unfinished text appeared in the result box")) return
        if (!test.check(target.translationPreview === "", "review-mode preview was populated")) return
      }
      if (test.stage === 0 && target.engines.length > 0 && !target.busy) {
        if (!test.check(!target.reviewTranslation, "review should default off")) return
        target.testToggleReview()
        test.stage = 1
      } else if (test.stage === 1 && !target.busy) {
        if (!test.check(target.reviewTranslation, "setting was not saved")) return
        target.translator = "ollama"
        target.sourceLanguage = "en"
        target.targetLanguage = "fr"
        target.setTestText("success")
        target.translate()
        test.stage = 2
      } else if (test.stage === 2) {
        if (target.translationStage === "reviewing" && target.translating && !test.changedSetting) {
          if (!test.check(target.translationStatus.indexOf("Reviewing translation") >= 0, "review status missing")) return
          target.savePreferences({reviewTranslation: false})
          test.changedSetting = true
        }
        if (!target.busy && test.changedSetting) {
          if (!test.check(target.translatedText === "FINAL REVIEW" && !target.reviewTranslation, "setting change disrupted the active review")) return
          target.performAction("copy")
          test.stage = 20
        }
      } else if (test.stage === 20 && !target.busy) {
        if (!test.check(target.copiedAction === "translation", "copy action failed")) return
        target.setTestText("single")
        target.translate()
        test.stage = 3
      } else if (test.stage === 3) {
        if (target.translationPreview === "PRIVATE DRAFT") test.sawSinglePreview = true
        if (!target.busy) {
          if (!test.check(test.sawSinglePreview && target.translatedText === "PRIVATE DRAFT", "single-pass streaming changed")) return
          target.testToggleReview()
          test.stage = 4
        }
      } else if (test.stage === 4 && !target.busy) {
        if (!test.check(target.reviewTranslation, "review not enabled")) return
        target.setTestText("failure")
        target.translate()
        test.stage = 5
      } else if (test.stage === 5) {
        if (target.translating && target.translationGeneratedCharacters > 0 && !test.queuedSettingOnFailure) {
          target.savePreferences({showHotkeys: false})
          test.queuedSettingOnFailure = true
        }
        if (!target.busy) {
          if (!test.check(target.translatedText === "" && target.message.indexOf("review failed") >= 0, "review failure message lost or draft displayed as final")) return
          if (!test.check(target.reviewRetryRequest.draft === "PRIVATE DRAFT" && target.canRetryReview, "draft or retry missing")) return
          target.retryReview()
          target.retryReview()
          test.stage = 6
        }
      } else if (test.stage === 6 && !target.busy) {
        if (!test.check(target.translatedText === "FINAL REVIEW" && target.reviewRetryRequest === null, "review-only retry failed")) return
        target.setTestText("cancelreview")
        target.translate()
        test.stage = 7
      } else if (test.stage === 7 && target.translationStage === "reviewing" && target.translationGeneratedCharacters > 0) {
        if (!test.check(target.canPerform("translate"), "cancel shortcut disabled during review")) return
        target.performAction("translate")
        test.stage = 8
      } else if (test.stage === 8 && !target.busy) {
        if (!test.check(target.translatedText === "" && target.canRetryReview && !target.messageError, "cancelled review lost draft or displayed it")) return
        target.retryReview()
        target.retryReview()
        test.stage = 9
      } else if (test.stage === 9 && !target.busy) {
        if (!test.check(target.translatedText === "FINAL REVIEW", "retry after cancellation failed")) return
        target.testTimeoutMs = 700
        target.setTestText("timeoutreview")
        target.translate()
        test.stage = 10
      } else if (test.stage === 10 && !target.busy) {
        if (!test.check(target.message.indexOf("Review timed out after 15 minutes") >= 0 && target.messageError && target.canRetryReview && target.translatedText === "", "review timeout mishandled")) return
        target.testTimeoutMs = 300000
        target.setTestText("canceltranslation")
        target.translate()
        test.stage = 11
      } else if (test.stage === 11 && target.translationGeneratedCharacters > 0) {
        target.performAction("translate")
        test.stage = 12
      } else if (test.stage === 12 && !target.busy) {
        if (!test.check(target.reviewRetryRequest === null && target.translatedText === "" && !target.messageError, "cancelled first pass displayed partial draft")) return
        target.reviewTranslation = false
        target.run("preferences.get", {}, function(reply) { target.applyPreferences(reply.data); test.restored = true })
        test.stage = 13
      } else if (test.stage === 13 && !target.busy && test.restored) {
        if (!test.check(target.reviewTranslation, "stored setting not restored")) return
        target.setTestText("guard")
        target.translationReviewEnabled = true
        var request = {text: "guard", translator: target.translator,
          sourceLanguage: target.sourceLanguage, targetLanguage: target.targetLanguage,
          activeProfileId: target.activeProfileId, openaiReasoningEffort: target.openaiReasoningEffort,
          draft: "PRIVATE DRAFT"}
        target.reviewRetryRequest = request
        target.finishTranslation(request, {ok: true, data: {translation: "UNVALIDATED DRAFT"}})
        if (!test.check(target.translatedText === "" && target.canRetryReview && target.messageError,
                        "unvalidated successful response was displayed")) return
        console.log("PASS: review lifecycle, hidden drafts, status, settings snapshot, retry deduplication, cancellation, timeout, persistence, single-pass streaming")
        Qt.quit()
      }
    }
  }
  Timer {
    interval: 25000
    running: true
    onTriggered: { console.error("FAIL: test timed out at stage " + test.stage); Qt.quit() }
  }
}
