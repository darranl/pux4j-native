package dev.pux4j.native_.substitutions;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;
import javafx.application.ConditionalFeature;

/**
 * GraalVM native image substitution for QuantumToolkit.isSupported.
 *
 * In native image there is a startup race: the FX application thread can process mouse
 * events before the render thread calls GraphicsPipeline.createPipeline(). The original
 * isSupported(SCENE3D) does getPipeline().is3DSupported() which throws NPE when the
 * pipeline is still null, killing the pick test and making all click handlers unreachable.
 *
 * This substitution avoids calling getPipeline() entirely. All pux4j applications are
 * 2D eInk apps — SCENE3D and EFFECT are never supported, SHAPE_CLIP is always supported,
 * and the other platform features (touch, virtual keyboard, etc.) are unused.
 */
@TargetClass(className = "com.sun.javafx.tk.quantum.QuantumToolkit")
final class QuantumToolkitSubstitution {

    @Substitute
    public boolean isSupported(ConditionalFeature feature) {
        return feature == ConditionalFeature.SHAPE_CLIP;
    }
}
