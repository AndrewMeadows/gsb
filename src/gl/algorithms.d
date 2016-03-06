
module gsb.gl.algorithms;

import gsb.core.log;
import gsb.core.color;
import gsb.core.singleton;
import gsb.core.window;
import gsb.glutils;
import derelict.opengl3.gl3;
import dglsl;
import gl3n.linalg;


class VertexArray {
    private GLuint handle = 0;
    auto get () {
        if (!handle)
            checked_glGenVertexArrays(1, &handle);
        return handle;
    }
    void release () {
        if (handle) {
            checked_glDeleteVertexArrays(1, &handle);
            handle = 0;
        }
    }
}

struct VertexAttrib {
    GLuint index;
    GLuint count;
    GLenum type;
    GLboolean normalized = GL_FALSE;
    GLsizei   stride = 0;
    const GLvoid* pointer = null;
}

struct DynamicVertexData {
    void* data; size_t length;
    VertexAttrib[] attribs;
}

struct DynamicVertexBatch {
    GLuint vao;
    GLenum type;
    GLsizei offset, count;
    DynamicVertexData[] components;
}

private auto toBase2Size (T) (T minSize) {
    T foo = 64;
    while (foo < minSize) foo <<= 1;
    return foo;
}


interface IDynamicRenderer {
    void drawArrays (VertexBatch batch);
    void drawElements (VertexBatch batch, ElementData elements);
    void release ();
}

// Dynamic, one-shot renderer that uses one vbo and unsynchronized glMapBuffer
// Impl of https://www.opengl.org/discussion_boards/showthread.php/170118-VBOs-strangely-slow?p=1197780#post1197780
private class UMapBatchedDynamicRenderer : IDynamicRenderer {
    mixin LowLockSingleton;

    GLuint vbo = 0;
    size_t bufferSize    = 1 << 20;  // 1 mb
    size_t bufferOffset  = 0;

    final void drawArrays (VertexBatch batch) {
        size_t neededLength = 0;
        foreach (component; batch.components)
            neededLength += component.length;

        bool needsRemap = false;

        if (neededLength + bufferOffset >= bufferSize) {
            // Orphan buffer, if it exists
            if (vbo) {
                checked_glBindBuffer(GL_ARRAY_BUFFER, vbo);
                checked_glBufferData(GL_ARRAY_BUFFER, bufferSize, null, GL_STREAM_DRAW);
            }

            // reset cursor
            bufferOffset = 0;

            // Check that our entire data set will fit within the buffer (if not, we need a bigger buffer)
            if (neededLength > bufferSize) {
                log.write("Large data store requested -- UMapRenderer resizing vbo from %ld to %ld",
                    bufferSize, toBase2Size(neededLength));
                bufferSize = toBase2Size(neededLength);
            }

            // Rebuild buffer
            if (!vbo) {
                checked_glGenBuffers(1, &vbo);
                checked_glBindBuffer(GL_ARRAY_BUFFER, vbo);
            }
            checked_glBufferData(GL_ARRAY_BUFFER, bufferSize, null, GL_STREAM_DRAW);

        // If vbo doesn't exist, create it
        } else if (!vbo) {
            checked_glGenBuffers(1, &vbo);
            checked_glBindBuffer(GL_ARRAY_BUFFER, vbo);
            checked_glBufferData(GL_ARRAY_BUFFER, bufferSize, null, GL_STREAM_DRAW);
            bufferOffset = 0;
        }

        // map vao + process components
        checked_glBindVertexArray(batch.vao);

        foreach (component; batch.components) {
            // map data...
            // ...
            foreach (attrib; component.attribs) {
                checked_glEnableVertexAttribArray(attrib.index);
                checked_glVertexAttribPointer(attrib.index, attrib.count, attrib.type, attrib.normalized, attrib.stride, attrib.pointer);
            }
        }
        checked_glDrawArrays(batch.type, batch.offset, batch.count);
    }

    final void drawElements (VertexBatch batch, ElementData elementData) {
        throw new Exception("Unimplemented!");
    }

    final void release () {
        if (vbo) {
            glDeleteBuffers(1, &vbo);
            vbo = 0;
        }
    }
}

private class BasicDynamicRenderer : IDynamicRenderer {
    mixin LowLockSingleton;

    private GLuint vbos[];

    private final void genVbos (size_t count) {
        int toCreate = cast(int)count - cast(int)vbos.length;
        if (toCreate > 0) {
            auto first = vbos.length;
            foreach (i; 0..toCreate)
                vbos ~= [ 0 ];
            checked_glGenBuffers(toCreate, vbos.ptr + first);
            log.write("BDR genereated %d vbos", toCreate);
        }
    }

    final void drawArrays (VertexBatch batch) {
        // create new vbos as necessary
        genVbos(batch.components.length);
        
        // buffer data + draw
        checked_glBindVertexArray(batch.vao);
        foreach (i; 0..batch.components.length) {
            checked_glBindBuffer(GL_ARRAY_BUFFER, vbos[i]);
            checked_glBufferData(GL_ARRAY_BUFFER, batch.components[i].length, batch.components[i].ptr, GL_STREAM_DRAW);
            foreach (attrib; batch.components[i].attrib) {
                checked_glVertexAttribPointer(attrib.index, attrib.count, attrib.type, attrib.normalized, attrib.stride, attrib.pointer);
            }
        }
        glDrawArrays(batch.type, batch.offset, batch.count);

        // orphan buffers so we can reuse them for the next drawcall (note: we're _not_ trying to be fast/efficient here; this is just a minimalistic
        // implementation that we can test against the others)
        foreach (i; 0..batch.components.length) {
            checked_glBufferData(GL_ARRAY_BUFFER, batch.components[i].length, null, GL_STREAM_DRAW);
        }
    }

    final void drawElements (VertexBatch batch, ElementData elementData) {
        // create new vbos as necessary
        genVbos(batch.components.length + 1);
        
        // buffer data + draw
        checked_glBindVertexArray(batch.vao);
        foreach (i; 0..batch.components.length) {
            checked_glBindBuffer(GL_ARRAY_BUFFER, vbos[i]);
            checked_glBufferData(GL_ARRAY_BUFFER, batch.components[i].length, batch.components[i].data, GL_STREAM_DRAW);
            foreach (attrib; batch.components[i].attrib) {
                checked_glVertexAttribPointer(attrib.index, attrib.count, attrib.type, attrib.normalized, attrib.stride, attrib.pointer);
            }
        }
        checked_glBindBuffer(GL_ELEMENT_BUFFER, vbos[batch.components.length]);
        checked_glBufferData(GL_ELEMENT_BUFFER, elementData.length, elementData.data, GL_STREAM_DRAW);
        glDrawElements(batch.type, batch.count);

        // orphan buffers so we can reuse them for the next drawcall (note: we're _not_ trying to be fast/efficient here; this is just a minimalistic
        // implementation that we can test against the others)
        foreach (i; 0..batch.components.length) {
            checked_glBindBuffer(GL_ARRAY_BUFFER, vbos[i]);
            checked_glBufferData(GL_ARRAY_BUFFER, batch.components[i].length, null, GL_STREAM_DRAW);
        }
        checked_glBindBuffer(GL_ELEMENT_BUFFER, vbos[batch.components.length]);
        checked_glBufferData(GL_ELEMENT_BUFFER, elementData.length, null, GL_STREAM_DRAW);
    }

    final void release () {
        if (vbos.length) {
            glDeleteBuffers(vbos.length, vbos[0]);
            vbos.length = 0;
        }
    }
}

struct DynamicRenderer {
    enum {
        NO_RENDERER = 0,
        UMAP_BATCHED_DYNAMIC_RENDERER,
        BASIC_DYNAMIC_RENDERER,
    }

    public  static __gshared auto renderer = BASIC_DYNAMIC_RENDERER;
    private static auto lastRenderer = NO_RENDERER;
    private static IDynamicRenderer _currentRenderer;

    private static IDynamicRenderer @property currentRenderer () {
        if (renderer == lastRenderer && _currentRenderer)
            return _currentRenderer;
        lastRenderer = renderer;
        switch (renderer) {
            case UMAP_BATCHED_DYNAMIC_RENDERER:  
                return _currentRenderer = UMapBatchedDynamicRenderer.instance;
            case BASIC_DYNAMIC_RENDERER: 
                return _currentRenderer = BasicDynamicRenderer.instance;
            default:
                throw new Exception("Invalid renderer!");
        }
    }

    static void drawElements (VertexArray vao, GLenum type, GLsizei offset, GLsizei count,
        DynamicVertexData[] vertexData, DynamicElementData elementData
    ) {
        currentRenderer.drawElements(
            DynamicVertexBatch(vao.get(), type, offset, count, vertexData), 
            elementData);
    }
    static void drawArrays (VertexArray vao, GLenum type, GLsizei offset, GLsizei count,
        DynamicVertexData[] vertexData)
    {
        currentRenderer.drawArrays(
            DynamicVertexBatch(vao.get(), type, offset, count, vertexData));
    }
}

void example {
    class Example : IRenderable {
        struct PackedData {
            vec2 position;
            float depth;
            float edgeDist;
        }
        struct State {
            VertexArray  vao;
            PackedData[] vertexData;
            ushort    [] indexData;

            protected void render () {
                DynamicRenderer.drawElements(vao.get(), 
                    GL_TRIANGLES, 0, cast(int)vertexData.length / 6, [
                        VertexData(vertexData.ptr, vertexData.length, [
                            VertexAttrib(0, 2, GL_FLOAT, GL_FALSE, PackedData.size, 0),
                            VertexAttrib(1, 1, GL_FLOAT, GL_FALSE, PackedData.size, vec2.size),
                            VertexAttrib(2, 1, GL_FLOAT, GL_FALSE, PackedData.size, vec2.size + float.size)
                        ])
                    ],  ElementData(indexData.ptr, indexData.length));
            }
        }
        State fstate, gstate;

        class MyShader {
            void bind () {}
            mat4 transform;
        }
        MyShader myshader;

        override void render () {
            synchronized { swap(fstate, gstate); }

            glState.enableDepthTest(false);
            glState.enableTransparency(true);

            myshader.bind();
            myshader.transform = g_mainWindow.screenSpaceTransform;

            gstate.render();
        }
    }

    class DebugRenderer2D {
        protected struct State {
            VertexArray vao;
            float[] vbuffer;
            int[]   ebuffer;

            protected void render (ref mat4 transform) {
                if (!vbuffer.length)
                    return;
                if (!vao)
                    checked_glGenVertexArrays(1, &vao);

                DynamicRenderer.drawArrays(vao.get(),
                    GL_TRIANGLES, 0, cast(int)vbuffer.length / 4, [
                        VertexData(vbuffer.ptr, vbuffer.length, [
                            VertexAttrib(0, 4, GL_FLOAT, GL_FALSE, 0, null)
                        ])
                    ]);

                DynamicRenderer.drawElements(vao.get(),
                    GL_TRIANGLES, 0, cast(int)vbuffer.length / 4, [

                    ]
            }
            protected void release () {
                vao.release();
            }
        }
    }
}































































































