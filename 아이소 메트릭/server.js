require('dotenv').config();
const express = require('express');
const cors = require('cors');
const path = require('path');
const { GoogleGenAI } = require('@google/genai');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// Initialize Google Gen AI only if API key is provided
let ai = null;
if (process.env.GEMINI_API_KEY) {
    ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
}

app.post('/api/generate', async (req, res) => {
    try {
        if (!ai) {
            return res.status(500).json({ error: 'GEMINI_API_KEY is not set in the server environment.' });
        }

        const { image, prompt } = req.body;
        
        if (!image || !prompt) {
            return res.status(400).json({ error: 'Image and prompt are required' });
        }

        // Assuming image is a base64 string, extract mime type and raw base64
        let base64Data = image;
        let mimeType = 'image/jpeg';
        
        if (image.startsWith('data:')) {
            const matches = image.match(/^data:([a-zA-Z0-9]+\/[a-zA-Z0-9-.+]+);base64,(.+)$/);
            if (matches) {
                mimeType = matches[1];
                base64Data = matches[2];
            }
        }

        // Call Gemini Model
        const response = await ai.models.generateContent({
            model: 'gemini-3.1-image-preview',
            contents: [
                {
                    role: 'user',
                    parts: [
                        {
                            inlineData: {
                                mimeType: mimeType,
                                data: base64Data
                            }
                        },
                        { text: prompt }
                    ]
                }
            ]
        });

        let generatedImageBase64 = null;
        let generatedText = null;

        // Extract native inline data if it returns an image
        if (response && response.candidates && response.candidates.length > 0) {
            const candidate = response.candidates[0];
            if (candidate.content && candidate.content.parts) {
                for (const part of candidate.content.parts) {
                    if (part.inlineData) {
                        generatedImageBase64 = `data:${part.inlineData.mimeType || 'image/png'};base64,${part.inlineData.data}`;
                    } else if (part.text) {
                        generatedText = part.text;
                    }
                }
            } else if (response.text) {
                try {
                    generatedText = response.text; // SDK method if available
                } catch (e) {
                    generatedText = response.text;
                }
            }
        }

        // Fallback: Check if the text response contains a formatted markdown image link or base64 structure
        if (!generatedImageBase64 && generatedText) {
            // Some image-generating models return a URL or base64 explicitly in text
            const base64Match = generatedText.match(/data:image\/[a-zA-Z0-9]+;base64,[a-zA-Z0-9+/=]+/);
            if (base64Match) {
                generatedImageBase64 = base64Match[0];
            }
        }

        res.json({
            success: true,
            image: generatedImageBase64,
            text: generatedText
        });

    } catch (error) {
        console.error('Error in /api/generate:', error);
        res.status(500).json({ error: error.message || 'Failed to generate image from AI' });
    }
});

app.listen(PORT, () => {
    console.log(`Server is running on http://localhost:${PORT}`);
});
