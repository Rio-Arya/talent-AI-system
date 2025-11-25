# Talent Match Intelligence System 🧠✨

This repository contains the Talent Match Intelligence System, a web application designed for HR professionals to identify the best internal candidates for job openings. The system leverages a benchmark-based approach, where high-performing employees are selected as a baseline to score and rank other talent within the organization. It combines a powerful SQL-based matching engine with AI-driven job profile generation to streamline the internal mobility and talent discovery process.

## Link 

https://talent-matching.streamlit.app/

## Answer 

1. EDA (https://github.com/Rio-Arya/talent-AI-system/blob/main/1.%20Analytic.ipynb
2. SQL (https://github.com/Rio-Arya/talent-AI-system/blob/main/talent_matching_query.sql)
3. App (https://talent-matching.streamlit.app/ || https://github.com/Rio-Arya/talent-AI-system/blob/main/streamlit_app.py)

## Key Features

*   **AI-Powered Job Profiling**: Automatically generate a comprehensive job profile, including requirements, description, and key competencies, based on a role's name, level, and purpose.
*   **Benchmark-Based Matching**: Select up to three high-performing employees to create a data-driven baseline for the ideal candidate.
*   **Weighted Scoring Engine**: A sophisticated PostgreSQL function calculates a `final_match_rate` for each employee across multiple dimensions:
    *   Competency Scores (SEA, QDD, FTC, etc.)
    *   Psychometric Profiles (Cognitive and Personality)
    *   Behavioral Strengths
    *   Contextual Background (Education, Tenure, Experience)
*   **Interactive Dashboards**: Visualize talent data with a ranked candidate list, match rate distributions, and average scores per talent group (TGV).
*   **Candidate-vs-Benchmark Comparison**: Use an interactive radar chart to visually compare a specific candidate's profile against the benchmark average, highlighting strengths and gaps.
*   **Audit & Vacancy Logging**: Automatically registers new vacancies and a ranked list of candidates to a database for auditing and historical tracking.

## How It Works

The system follows a clear data flow to deliver its insights:

1.  **Input**: A user defines the new role's details (e.g., "Sales", "Junior", purpose) and selects 1-3 benchmark employees from a dropdown list in the Streamlit sidebar.
2.  **AI Generation**: The role details are sent to the OpenRouter API (using the `x-ai/grok-code-fast-1` model), which returns a structured markdown job profile.
3.  **Database Query**: The IDs of the benchmark employees are passed to the `get_talent_matches` PostgreSQL function hosted on Supabase.
4.  **Matching Engine**:
    *   The SQL function calculates an average "baseline" profile from the benchmark employees' data.
    *   It then scores every employee in the database against this baseline, applying predefined weights to different attributes.
    *   The function returns a detailed breakdown of match scores for each employee.
5.  **Visualization**: The Streamlit application receives the data, processes it with Pandas, and displays the results through ranked tables and interactive Plotly charts.

## Technology Stack

*   **Frontend**: [Streamlit](https://streamlit.io/)
*   **Backend & Database**: [Supabase](https://supabase.com/) (PostgreSQL)
*   **AI Model**: [OpenRouter API](https://openrouter.ai/) (via `openai` library)
*   **Data Processing**: [Pandas](https://pandas.pydata.org/), [NumPy](https://numpy.org/)
*   **Data Visualization**: [Plotly](https://plotly.com/)
*   **Environment Management**: [python-dotenv](https://pypi.org/project/python-dotenv/)

## Setup and Installation

### Prerequisites

*   Python 3.8+
*   Access to a Supabase project.
*   An API key from OpenRouter.

### 1. Database Setup

This application requires a specific database schema and a custom PostgreSQL function.

1.  Set up your Supabase project with tables for employees, psychometric profiles, competencies, etc. The query in `talent_matching_query.sql` reveals the expected schema structure (e.g., `employees`, `profiles_psych`, `competencies_yearly`, `dim_directorates`).
2.  Navigate to the **SQL Editor** in your Supabase project dashboard.
3.  Copy the entire content of `talent_matching_query.sql` and run it to create the `get_talent_matches(jsonb)` function.

### 2. Local Setup

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/rio-arya/talent-ai-system.git
    cd talent-ai-system
    ```

2.  **Create an environment file:**
    Create a file named `.env` in the root directory and add your credentials:
    ```env
    # Supabase Credentials
    SUPABASE_URL="YOUR_SUPABASE_PROJECT_URL"
    SUPABASE_KEY="YOUR_SUPABASE_ANON_KEY"

    # OpenRouter API Key
    api_key="YOUR_OPENROUTER_API_KEY"
    ```

3.  **Install dependencies:**
    ```bash
    pip install -r requirements.txt
    ```

4.  **Run the application:**
    ```bash
    streamlit run streamlit_app.py
    ```
The application will be available at `http://localhost:8501`.

## Usage Guide

1.  Open the application in your browser.
2.  In the left sidebar, enter the **Role Name**, select the **Job Level**, and describe the **Role Purpose**.
3.  From the multiselect dropdown, choose one to three "benchmark" employees who exemplify the qualities needed for the role.
4.  Click the **✨ Generate Profile & Matches** button.
5.  The main panel will refresh to display:
    *   The AI-generated job profile.
    *   A ranked table of the top internal candidates.
    *   Dashboard charts showing the distribution of match scores.
    *   A comparison section at the bottom to analyze individual candidates against the benchmark.

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
