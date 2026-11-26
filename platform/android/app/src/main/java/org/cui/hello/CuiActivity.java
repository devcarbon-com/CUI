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
                @Override
                public boolean commitText(CharSequence text, int newCursorPosition) {
                    if (text != null) nativeCommitText(text.toString());
                    return true;
                }

                @Override
                public boolean deleteSurroundingText(int beforeLength, int afterLength) {
                    nativeDeleteChars(Math.max(0, beforeLength));
                    return true;
                }

                @Override
                public boolean sendKeyEvent(KeyEvent event) {
                    // native_app_glue already delivers every key event to the
                    // native input queue; forwarding again would double them
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
    private native void nativeDeleteChars(int n);
}
