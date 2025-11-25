import streamlit as st
import pandas as pd
import numpy as np
import os
from dotenv import load_dotenv
from supabase import create_client, Client
import openai
import plotly.express as px
import plotly.graph_objects as go

# --- PAGE CONFIGURATION ---
# Set page layout to wide and define the title shown in the browser tab
st.set_page_config(layout="wide", page_title="Talent Match App")

# --- SUPABASE CONNECTION ---
# Cache the Supabase client to avoid reconnecting on every script rerun
@st.cache_resource
def get_supabase_client():
    """Establishes a connection to Supabase using credentials from .env."""
    # Load .env file from the same directory
    load_dotenv()  # Load environment variables
    
    # Retrieve Supabase connection details from environment variables
    supabase_url = os.getenv('SUPABASE_URL')
    supabase_key = os.getenv('SUPABASE_KEY')
    
    # Create and return a Supabase client
    return create_client(supabase_url, supabase_key)

# Initialize the Supabase client
supabase: Client = get_supabase_client()

# --- LOAD BASE SQL QUERY ---
# Cache the base SQL query data to avoid rereading the file on every script rerun
@st.cache_data
def load_base_query():
    """Loads SQL from talent_matching_query.sql reliably in Streamlit."""
    sql_file_path = os.path.join(os.getcwd(), "talent_matching_query.sql")

    if not os.path.isfile(sql_file_path):
        st.error(f"SQL file not found at: {sql_file_path}")
        return None

    with open(sql_file_path, "r", encoding="utf-8") as file:
        return file.read()


# Store the loaded base SQL query (optional, for reference)
base_sql_query = load_base_query()

# --- FETCH EMPLOYEE LIST ---
# Cache the employee list data
@st.cache_data
def get_employee_list():
    """Fetches employee IDs and full names from Supabase for selection widgets."""
    # Query the employees table using Supabase client
    response = supabase.table('employees') \
        .select('employee_id, fullname') \
        .order('fullname') \
        .execute()
    
    # Convert response to pandas DataFrame
    df = pd.DataFrame(response.data)
    
    # Create a display column combining name and ID for user-friendliness in widgets
    df['display'] = df['fullname'] + " (" + df['employee_id'] + ")"
    return df

# --- EXECUTE SQL QUERY ---
# Helper function to execute raw SQL queries via Supabase RPC
def execute_sql_query(sql_query):
    """
    Executes a raw SQL query using Supabase RPC function.
    Note: You need to create a PostgreSQL function in Supabase for this.
    """
    try:
        # Execute using Supabase's rpc method
        response = supabase.rpc('execute_sql', {'query': sql_query}).execute()
        return pd.DataFrame(response.data)
    except Exception as e:
        st.error(f"Error executing query: {str(e)}")
        return pd.DataFrame()

# --- INITIALIZE OPENAI ---
# Load OpenAI API key from environment (same directory)
load_dotenv()
openai.api_key = os.getenv('api_key')

# --- GENERATE AI JOB PROFILE ---
# Cache the generated job profile based on inputs
@st.cache_data
def generate_job_profile(role_name, job_level, role_purpose):
    """Generates a job profile using an AI model via OpenRouter API."""
    # Retrieve the API key from environment variables
    api_key = os.getenv("api_key")  # Using the same api_key from .env
    if not api_key:
        return "Error: Missing API key. Please set it in your .env file."
    
    # Define the prompt for the AI model
    prompt = f"""
    Generate a concise job profile for the following role:
    Role: {role_name}
    Level: {job_level}
    Purpose: {role_purpose}
    
    Structure the output using markdown with these sections:
    ## Job Requirements
    - Provide 5 to 7 key requirements as bullet points.
    
    ## Job Description
    - Write a brief paragraph summarizing the role's responsibilities.
    
    ## Key Competencies
    - List 5 essential competencies as bullet points.
    """
    
    try:
        client = openai.OpenAI(base_url="https://openrouter.ai/api/v1", api_key=api_key)
        
        response = client.chat.completions.create(
            model="x-ai/grok-code-fast-1",
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior HR assistant. "
                        "Create clear, concise, actionable job profiles including "
                        "role purpose, responsibilities, skills, and KPIs."
                    )
                },
                {"role": "user", "content": prompt}
            ],
            max_tokens=400,
            temperature=0.6
        )

        # Grok returns .text; some OpenRouter chat models return message.content
        choice = response.choices[0]
        if hasattr(choice, "text"):  # Grok / older models
            result = choice.text
        elif hasattr(choice, "message") and hasattr(choice.message, "content"):  # OpenAI-style
            result = choice.message.content
        else:
            result = str(choice)  # fallback

        return result.strip()

    except Exception as e:
        st.error(f"Error generating AI profile: {e}")
        return "Failed to generate AI profile."


# --- MAIN STREAMLIT UI ---
st.title("Talent Match Intelligence System 🧠✨")
st.markdown("Use the sidebar to input vacancy details and select benchmark employees to generate ranked matches.")

# --- SIDEBAR FOR INPUTS ---
with st.sidebar:
    st.header("Vacancy & Benchmark Settings")
    
    # Input fields for vacancy details
    role_name_input = st.text_input("Role Name", "Sales")  # Default role name
    job_level_input = st.selectbox("Job Level", ["Entry-Level", "Junior", "Senior", "Executive"], index=1)  # Default to Supervisor
    role_purpose_input = st.text_area(
    label="Role Purpose",
    value="Drive sales growth by identifying customer needs, building strong client relationships, and achieving revenue targets across assigned territories.",
    height=150,
    placeholder="Describe the main purpose and responsibilities of this Sales role...")

    
    # Fetch employee list for the multiselect widget
    employee_list_df = get_employee_list()
    
    # Multiselect widget for choosing benchmark employees
    selected_benchmarks = st.multiselect(
        "Select up to 3 benchmark employees:",
        options=employee_list_df['display'],  # Show "Fullname (ID)"
        max_selections=3,
    )
    
    # Extract only the employee IDs from the selected display strings
    selected_benchmark_ids = [display_str.split('(')[-1].replace(')', '') for display_str in selected_benchmarks]
    
    # Button to trigger the query execution and profile generation
    generate_button = st.button("✨ Generate Profile & Matches")

# --- EXECUTE SQL QUERY ---
# This block runs only when the 'Generate' button is clicked
if generate_button:
    # Check if benchmark employees are selected
    if not selected_benchmark_ids:
        st.sidebar.error("Please select at least one benchmark employee.")
    else:
        # Show a spinner while the query is running
        with st.spinner("Analyzing talent data... ⏳"):
            try:
                # Call the get_talent_matches function directly via RPC
                # Convert selected_benchmark_ids to JSONB format
                benchmark_ids_json = selected_benchmark_ids
                
                response = supabase.rpc(
                    'get_talent_matches', 
                    {'benchmark_ids': benchmark_ids_json}
                ).execute()
                
                # Convert response to DataFrame
                if response.data:
                    df_sql_results = pd.DataFrame(response.data)
                    st.success("✅ Analysis complete!")
                else:
                    df_sql_results = pd.DataFrame()
                    st.warning("Query executed but returned no data.")
                
                # Store the results and inputs in Streamlit's session state
                # Store the results and inputs in Streamlit's session state
                st.session_state.sql_results = df_sql_results
                st.session_state.inputs = {
                    'role': role_name_input,
                    'level': job_level_input,
                    'purpose': role_purpose_input,
                    'benchmarks': selected_benchmark_ids
                }

                inputs = st.session_state.inputs

                # -----------------------------------------------------------
                # VACANCY REGISTRATION
                # -----------------------------------------------------------
                try:
                    vacancy_insert = supabase.table("job_vacancies").insert({
                        "role_name": inputs['role'],
                        "job_level": inputs['level'],
                        "role_purpose": inputs['purpose'],
                        "benchmark_ids": inputs['benchmarks']
                    }).execute()

                    vacancy_id = vacancy_insert.data[0]['vacancy_id']
                    st.session_state.vacancy_id = vacancy_id
                    st.success(f"📌 Vacancy registered (ID: {vacancy_id})")

                except Exception as e:
                    st.error(f"❌ Failed to insert vacancy: {e}")
                    vacancy_id = None


                # -----------------------------------------------------------
                # AUDIT TRAIL CREATION: store ranked candidates
                # -----------------------------------------------------------
                if vacancy_id and not df_sql_results.empty:
                    try:
                        audit_payload = []
                        for _, row in df_sql_results.iterrows():
                            audit_payload.append({
                                "vacancy_id": vacancy_id,
                                "candidate_id": row['employee_id'],
                                "match_rate": row.get('final_match_rate', None),
                                "gap_report": {},  # Will be filled below
                                "recommendations": None
                            })

                        supabase.table("vacancy_audit").insert(audit_payload).execute()
                        st.success("📚 Audit trail recorded.")

                    except Exception as e:
                        st.error(f"❌ Failed to store audit trail: {e}")
                
            except Exception as e:
                # Display database errors clearly
                st.error("❌ Database query failed")



# --- DISPLAY RESULTS ---
# This block runs if results are available in the session state
if 'sql_results' in st.session_state:
    # Retrieve the DataFrame and inputs from session state
    df = st.session_state.sql_results
    inputs = st.session_state.inputs
    employee_list_df = get_employee_list()

    try:
        # --- Display AI Generated Job Profile ---
        st.write("---")
        st.subheader("🤖 AI-Generated Job Profile")
        ai_profile = generate_job_profile(inputs['role'], inputs['level'], inputs['purpose'])
        st.markdown(ai_profile)

        # --- Calculate Top TGV (Domain) for each employee ---
        st.write("---")
        st.subheader("📊 Ranked Talent List")
        
        df_top_tgv = pd.DataFrame()
        if not df.empty and 'tgv_match_rate' in df.columns and 'tgv_name' in df.columns:
            # Get unique TGV rate per employee/TGV combination
            df_unique_tgv = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
            # Find the top TGV for each employee
            idx = df_unique_tgv.loc[df_unique_tgv.groupby('employee_id')['tgv_match_rate'].idxmax()]
            df_top_tgv = idx[['employee_id', 'tgv_name']].copy()
            df_top_tgv.rename(columns={'tgv_name': 'top_tgv'}, inplace=True)

        # Create the base ranked DataFrame
        df_ranked = df[['employee_id', 'role', 'grade', 'directorate', 'final_match_rate', 'is_benchmark']].drop_duplicates('employee_id').copy()
        df_ranked = pd.merge(df_ranked, employee_list_df[['employee_id', 'fullname']], on='employee_id', how='left')

        # Drop employees with missing fullname (hapus 'No Name Found' dari tampilan)
        df_ranked = df_ranked[~df_ranked['fullname'].isna()]
        df_ranked = df_ranked[df_ranked['fullname'] != ""]


        # Merge Top TGV information
        if not df_top_tgv.empty:
            df_ranked = pd.merge(df_ranked, df_top_tgv, on='employee_id', how='left')
            df_ranked['top_tgv'] = df_ranked['top_tgv'].fillna('N/A')
        else:
            df_ranked['top_tgv'] = 'N/A'

        # Filter candidates (exclude benchmarks)
        df_ranked_candidates = df_ranked[df_ranked['is_benchmark'] == False].copy()
        df_ranked_candidates = df_ranked_candidates.sort_values('final_match_rate', ascending=False).reset_index(drop=True)
        df_ranked_candidates.insert(0, 'Rank', range(1, len(df_ranked_candidates) + 1))

        # Display ranked list
        st.dataframe(
            df_ranked_candidates[['Rank', 'employee_id', 'fullname', 'final_match_rate','role', 'grade', 'directorate', 'top_tgv']],
            column_config={
                "final_match_rate": st.column_config.ProgressColumn(
                    "Match Rate",
                    format="%.1f%%",
                    min_value=0,
                    max_value=100
                ),
                "top_tgv": st.column_config.TextColumn("Top TGV")
            },
            hide_index=True,
            use_container_width=True
        )

        # --- Dashboard Visualizations ---
        st.write("---")
        st.subheader("📈 Dashboard Visualizations")
        
        # Two columns for charts
        col1, col2 = st.columns(2)

        # Chart 1: Match Rate Distribution
        with col1:
            st.markdown("**Match Rate Distribution (Candidates)**")
            if not df_ranked_candidates.empty:
                fig_hist = px.histogram(
                    df_ranked_candidates, 
                    x="final_match_rate", 
                    nbins=20,
                    labels={'final_match_rate': 'Final Match Rate (%)'},
                    color_discrete_sequence=['#636EFA']
                )
                fig_hist.update_layout(
                    yaxis_title="Number of Candidates", 
                    bargap=0.1, 
                    xaxis_range=[0,100],
                    showlegend=False
                )
                st.plotly_chart(fig_hist, use_container_width=True)
            else:
                st.warning("No candidate data available.")

        # Chart 2: Average TGV Match Rate
        with col2:
            st.markdown("**Average Match Rate per TGV (All Employees)**")
            if not df.empty and 'tgv_match_rate' in df.columns:
                df_tgv_unique = df[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates()
                avg_tgv = df_tgv_unique.groupby('tgv_name')['tgv_match_rate'].mean().reset_index()
                avg_tgv = avg_tgv.sort_values('tgv_match_rate', ascending=True)
                
                fig_tgv = px.bar(
                    avg_tgv, 
                    x='tgv_match_rate', 
                    y='tgv_name', 
                    orientation='h',
                    text_auto='.1f',
                    labels={'tgv_match_rate': 'Avg Match Rate (%)', 'tgv_name': 'TGV'},
                    color_discrete_sequence=['#EF553B']
                )
                fig_tgv.update_layout(xaxis_range=[0,100])
                st.plotly_chart(fig_tgv, use_container_width=True)
            else:
                st.warning("No TGV data available.")

        # --- Benchmark vs. Candidate Comparison ---
        st.write("---")
        st.subheader("🔍 Benchmark vs. Candidate Comparison")

        if not df_ranked_candidates.empty:
            # Candidate selection
            candidate_options = df_ranked_candidates['employee_id'] + " - " + df_ranked_candidates['fullname']
            selected_candidate_display = st.selectbox("Select Candidate:", options=candidate_options)
            selected_candidate_id = selected_candidate_display.split(" - ")[0]

            # Filter data
            benchmark_data = df[df['is_benchmark']]
            candidate_data = df[df['employee_id'] == selected_candidate_id]

            # Calculate averages
            bench_tgv_avg = benchmark_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()
            cand_tgv_avg = candidate_data[['employee_id', 'tgv_name', 'tgv_match_rate']].drop_duplicates().groupby('tgv_name')['tgv_match_rate'].mean()

            # Prepare radar chart data
            default_tgvs = [
                'Competency',
                'Psychometric (Cognitive)',
                'Psychometric (Personality)',
                'Behavioral (Strengths)',
                'Contextual (Background)',
            ]
            radar_df = pd.DataFrame({'tgv_name': default_tgvs})
            radar_df['Benchmark Avg'] = radar_df['tgv_name'].map(bench_tgv_avg).fillna(0)
            radar_df['Candidate'] = radar_df['tgv_name'].map(cand_tgv_avg).fillna(0)

            # Create radar chart
            fig_radar = go.Figure()
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Benchmark Avg'],
                theta=radar_df['tgv_name'],
                fill='toself',
                name='Benchmark Average',
                line_color='lightcoral'
            ))
            fig_radar.add_trace(go.Scatterpolar(
                r=radar_df['Candidate'],
                theta=radar_df['tgv_name'],
                fill='toself',
                name=f'Candidate ({selected_candidate_id})',
                line_color='skyblue'
            ))
            fig_radar.update_layout(
                polar=dict(radialaxis=dict(visible=True, range=[0, 100])),
                showlegend=True,
                title=f"TGV Comparison: Benchmark vs {selected_candidate_id}"
            )
            st.plotly_chart(fig_radar, use_container_width=True)

            # Summary Insights
            st.markdown("**💡 Summary Insights:**")
            diffs = radar_df['Candidate'] - radar_df['Benchmark Avg']
            
            if diffs.notna().any():
                idx_max_diff = diffs.idxmax()
                idx_min_diff = diffs.idxmin()
                
                col_insight1, col_insight2 = st.columns(2)
                
                with col_insight1:
                    st.success(
                        f"**🌟 Strongest Area:**\n\n"
                        f"{radar_df.loc[idx_max_diff, 'tgv_name']}\n\n"
                        f"Candidate: {radar_df.loc[idx_max_diff, 'Candidate']:.1f}% | "
                        f"Benchmark: {radar_df.loc[idx_max_diff, 'Benchmark Avg']:.1f}%"
                    )
                
                with col_insight2:
                    st.warning(
                        f"**⚠️ Largest Gap:**\n\n"
                        f"{radar_df.loc[idx_min_diff, 'tgv_name']}\n\n"
                        f"Candidate: {radar_df.loc[idx_min_diff, 'Candidate']:.1f}% | "
                        f"Benchmark: {radar_df.loc[idx_min_diff, 'Benchmark Avg']:.1f}%"
                    )
                
                # Why this candidate ranks high
                st.markdown("**📋 Why This Candidate Ranks High:**")
                top_tgvs = radar_df.nlargest(3, 'Candidate')
                reasons = []
                for idx, row in top_tgvs.iterrows():
                    if row['Candidate'] >= row['Benchmark Avg']:
                        reasons.append(f"- Strong {row['tgv_name']} ({row['Candidate']:.1f}%)")
                
                if reasons:
                    st.markdown("\n".join(reasons))
                else:
                    st.info("This candidate shows balanced performance across all TGVs.")
            else:
                st.info("Could not determine detailed comparison insights.")

        else:
            st.info("No candidates available for comparison.")

    except Exception as e:
        st.error(f"An error occurred while displaying results: {e}")
        st.exception(e)