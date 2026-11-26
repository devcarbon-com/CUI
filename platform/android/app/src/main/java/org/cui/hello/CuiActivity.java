package org.cui.hello;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Bundle;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

/* NativeActivity's input queue never sees IME commitText, which is how soft
 * keyboards (swipe typing in particular) deliver text, and the decor view the
 * native code shows the IME on is not a text editor, so the IME has nothing
 * to connect to. CuiInputView is a 1x1 invisible text-editor view the IME can
 * bind to; its InputConnection forwards composed text and deletions to the
 * native backend over JNI. */
public class CuiActivity extends NativeActivity {

    static {
        // the JVM must resolve nativeCommitText/nativeDeleteChars; NativeActivity
        // loads libnotes.so itself but on a classloader this activity doesn't share
        System.loadLibrary("notes");
    }

    private View input;

    private class CuiInputView extends View {
        CuiInputView(Context c) { super(c); }

        @Override
        public boolean onCheckIsTextEditor() { return true; }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
            outAttrs.inputType = android.text.InputType.TYPE_CLASS_TEXT;
            outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_ACTION_NONE;
        return new BaseInputConnection(this, false) {
            int span = 0;               /* composing-span codepoints */
            String spanText = "";       /* what we typed for it */

            @Override
            public boolean commitText(CharSequence text, int newCursorPosition) {
                /* a commit can also arrive while composing is still active
                 * (space after a suggestion): the prefix we typed via
                 * setComposingText is already on screen, so only the tail
                 * must be committed */
                if (text != null) {
                    String t = text.toString();
                    if (t.startsWith(spanText))
                        t = t.substring(spanText.length());
                    else if (span > 0) nativeDeleteSpanCodepoints(span);
                    if (!t.isEmpty()) nativeCommitText(t);
                }
                span = 0;
                spanText = "";
                return true;
            }

            /* The composing span (typed-but-not-final text) is diffed HERE in
             * Java: each normal keystroke extends the span by exactly one
             * char and is forwarded as a plain commit (zero lag, no
             * backspacing). Only when the IME rewrites the span (autocorrect,
             * swipe suggestion, length change) do we delete what we typed
             * before and re-type the new text. */
            @Override
            public boolean setComposingText(CharSequence text, int newCursorPosition) {
                String t = text != null ? text.toString() : "";
                int n = t.codePointCount(0, t.length());
                if (n != span) {
                    /* extension of what we typed (steady keystroke): only the
                     * new tail is missing on screen; a rewrite (autocorrect,
                     * swipe suggestion) deletes the old span first */
                    boolean extend = span > 0 && spanText != null && t.startsWith(spanText);
                    if (!extend && span > 0) nativeDeleteSpanCodepoints(span);
                    String tail = extend ? t.substring(spanText.length()) : t;
                    spanText = t;
                    span = n;
                    if (!tail.isEmpty()) nativeCommitText(tail);
                }
                return true;
            }

            @Override
            public boolean deleteSurroundingText(int beforeLength, int afterLength) {
                // a backspace inside the span: the following setComposingText
                // lands at a smaller span and re-syncs us; forward the delete
                beforeLength = Math.max(0, beforeLength);
                nativeDeleteChars(beforeLength);
                span = Math.max(0, span - beforeLength);
                if (spanText.length() > 0) {
                    int cut = Math.min(beforeLength, spanText.length());
                    spanText = spanText.substring(0, spanText.length() - cut);
                }
                return true;
            }

            @Override
            public boolean sendKeyEvent(KeyEvent event) {
                /* soft-keyboard key events (backspace, arrows, enter) reach
                 * only this method, never the native input queue; forward
                 * them to native and swallow here (no super, or they double) */
                if (event.getAction() == KeyEvent.ACTION_DOWN)
                    nativeKeyEvent(event.getKeyCode());
                return true;
            }
        };
        }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        input = new CuiInputView(this);
        android.widget.FrameLayout.LayoutParams lp = new android.widget.FrameLayout.LayoutParams(1, 1);
        lp.gravity = Gravity.BOTTOM | Gravity.START;
        addContentView(input, lp);
    }

    /* called from the native (glue) thread; the IME must be driven on the UI thread */
    public void showKeyboard() {
        runOnUiThread(() -> {
            input.setFocusable(true);
            input.setFocusableInTouchMode(true);
            input.requestFocus();
            InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.showSoftInput(input, 0);
        });
    }

    public void hideKeyboard() {
        runOnUiThread(() -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
            input.setFocusable(false);
            input.setFocusableInTouchMode(false);
            input.clearFocus();
        });
    }

    private native void nativeCommitText(String utf8);
    private native void nativeDeleteSpanCodepoints(int n);
    private native void nativeDeleteChars(int n);
    private native void nativeKeyEvent(int code);
}
